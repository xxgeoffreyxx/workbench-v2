import Foundation

/// The menu bar's list has exactly two kinds of item: jobs running right now, and chats with a reply waiting that
/// hasn't been read. No history. Running jobs first, then unread chats; newest first within each.
public enum MenuFeed {
    public static let limit = 15

    public struct Chat: Hashable, Sendable {
        public let id: UUID
        public let title: String
        public let updatedAt: Date
        public let busy: Bool
        public let unread: Bool

        public init(id: UUID, title: String, updatedAt: Date, busy: Bool, unread: Bool) {
            self.id = id
            self.title = title
            self.updatedAt = updatedAt
            self.busy = busy
            self.unread = unread
        }
    }

    public enum Marker: Hashable, Sendable {
        case none, running, unread
    }

    public enum Target: Hashable, Sendable {
        case job(String)
        case chat(UUID)
    }

    public struct Item: Hashable, Sendable {
        public let target: Target
        public let title: String
        public let detail: String
        public let marker: Marker
        public let date: Date
    }

    public struct Feed: Sendable {
        public let items: [Item]
        public let hasMore: Bool
    }

    public static func build(jobs: [JobRecord], chats: [Chat], now: Date = Date()) -> Feed {
        let all = allItems(jobs: jobs, chats: chats, now: now)
        return Feed(items: Array(all.prefix(limit)), hasMore: all.count > limit)
    }

    public static func items(jobs: [JobRecord], chats: [Chat], now: Date = Date()) -> [Item] {
        build(jobs: jobs, chats: chats, now: now).items
    }

    /// A chat is unread when a reply landed after the user last looked at it. No baseline yet means not unread,
    /// so existing chats don't all light up the first time this runs.
    public static func isUnread(lastReplyAt: Date?, lastViewedAt: Date?) -> Bool {
        guard let lastReplyAt, let lastViewedAt else { return false }
        return lastReplyAt > lastViewedAt
    }

    static func allItems(jobs: [JobRecord], chats: [Chat], now: Date) -> [Item] {
        let jobItems = jobs.filter { $0.status == .running }.map { job in
            Item(target: .job(job.id), title: job.title,
                 detail: "\(job.workflow.rawValue) · Started: \(ShortAge.text(for: job.startedAt ?? job.updatedAt, now: now))",
                 marker: .running, date: job.startedAt ?? job.updatedAt)
        }
        // Only chats with a reply waiting that hasn't been read; a chat still generating shows up once its reply lands.
        let chatItems = chats.filter(\.unread).map { chat in
            Item(target: .chat(chat.id), title: chat.title.isEmpty ? "Untitled" : chat.title,
                 detail: "Chat · new reply · \(ShortAge.text(for: chat.updatedAt, now: now))",
                 marker: .unread, date: chat.updatedAt)
        }
        return (jobItems + chatItems).sorted {
            let lhsRunning = $0.marker == .running
            let rhsRunning = $1.marker == .running
            if lhsRunning != rhsRunning { return lhsRunning }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86_400)d"
    }
}

/// Order of the menu bar menu: what's running, the models, then Open / Settings / Quit at the bottom.
public enum MenuLayout {
    public enum Slot: Hashable, Sendable {
        case running, separator, models, refreshStatus, open, settings, quit, newChat, quickChat

        public var title: String {
            switch self {
            case .open: return "Open"
            case .settings: return "Settings…"
            case .quit: return "Quit Workbench"
            case .refreshStatus: return "Refresh Status"
            case .newChat: return "New Chat"
            case .quickChat: return "Quick Chat"
            case .running, .separator, .models: return ""
            }
        }

        public var key: String {
            switch self {
            case .open: return "o"
            case .settings: return ","
            case .quit: return "q"
            default: return ""
            }
        }
    }

    public static let order: [Slot] = [.running, .separator, .models, .separator, .open, .settings, .quit]
}
