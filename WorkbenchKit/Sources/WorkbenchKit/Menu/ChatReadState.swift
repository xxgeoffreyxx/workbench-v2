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
}
