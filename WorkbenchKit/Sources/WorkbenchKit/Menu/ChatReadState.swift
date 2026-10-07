import Foundation

/// Which chats have been read, as stored in UserDefaults: a startup baseline plus a viewed time per chat id.
/// Looking a chat up never records it as viewed; only markViewed does, so a reply that lands before the first
/// menu lookup stays unread.
public struct ChatReadState: Equatable {
    /// Seconds since 1970 when unread tracking started. Nothing older counts as new.
    public var baseline: Double
    /// Chat id -> seconds since 1970 when the user last viewed it.
    public var viewed: [String: Double]

    public init(baseline: Double, viewed: [String: Double] = [:]) {
        self.baseline = baseline
        self.viewed = viewed
    }

    /// When the chat was last looked at: its viewed time, never earlier than the baseline.
    public func lastViewed(_ id: String) -> Date {
        Date(timeIntervalSince1970: max(viewed[id] ?? baseline, baseline))
    }

    public mutating func markViewed(_ id: String, at date: Date) {
        viewed[id] = date.timeIntervalSince1970
    }

    public func isUnread(_ id: String, lastReplyAt: Date?) -> Bool {
        MenuFeed.isUnread(lastReplyAt: lastReplyAt, lastViewedAt: lastViewed(id))
    }

    public typealias MessageStamp = (date: Date?, isOwn: Bool)

    /// The unread source for a chat: the newest timestamp among messages the user did not write. Own sends,
    /// project moves and other metadata edits (which bump the chat's updatedDate) never count as a reply.
    public static func lastAssistantReply(_ messages: [MessageStamp]) -> Date? {
        messages.filter { !$0.isOwn }.compactMap(\.date).max()
    }

    /// When the app becomes active again: the chat to mark viewed, if one is actually on screen. A reply that
    /// landed while the app was in the background is otherwise never marked read for the chat already open.
    public static func chatToMarkOnActivation<ID>(
        isActive: Bool, windowVisible: Bool, chatsTabShown: Bool, selectedChat: ID?
    ) -> ID? {
        guard isActive, windowVisible, chatsTabShown else { return nil }
        return selectedChat
    }

    // MARK: - Persistence

    public static let baselineKey = "workbench.chatUnreadSince"
    public static let viewedKey = "workbench.chatLastViewed"

    /// Called when the app starts, before any chat activity: sets the baseline once, so a reply that lands
    /// before the first menu lookup is newer than it. An existing baseline is never moved.
    public static func startup(defaults: UserDefaults, now: Date = Date()) {
        if defaults.object(forKey: baselineKey) == nil {
            defaults.set(now.timeIntervalSince1970, forKey: baselineKey)
        }
    }

    /// Read state for a lookup. Falls back to creating the baseline only if startup never ran.
    public static func load(defaults: UserDefaults, now: Date = Date()) -> ChatReadState {
        let since = defaults.object(forKey: baselineKey) as? Double ?? {
            let t = now.timeIntervalSince1970
            defaults.set(t, forKey: baselineKey)
            return t
        }()
        return ChatReadState(baseline: since, viewed: defaults.dictionary(forKey: viewedKey) as? [String: Double] ?? [:])
    }
}
