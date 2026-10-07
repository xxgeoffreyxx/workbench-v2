import XCTest
@testable import WorkbenchKit

final class ChatReadStateTests: XCTestCase {
    let id = "chat-1"
    let baseline = Date(timeIntervalSince1970: 1_000)

    func testReplyAfterBaselineBeforeAnyLookupIsUnread() {
        let state = ChatReadState(baseline: baseline.timeIntervalSince1970)
        XCTAssertTrue(state.isUnread(id, lastReplyAt: Date(timeIntervalSince1970: 1_050)))
    }

    func testLookupDoesNotMarkViewed() {
        let state = ChatReadState(baseline: baseline.timeIntervalSince1970)
        let reply = Date(timeIntervalSince1970: 1_050)
        _ = state.lastViewed(id)
        XCTAssertTrue(state.isUnread(id, lastReplyAt: reply))
        XCTAssertTrue(state.isUnread(id, lastReplyAt: reply), "second lookup must still be unread")
        XCTAssertNil(state.viewed[id])
    }

    func testMarkViewedMakesItRead() {
        var state = ChatReadState(baseline: baseline.timeIntervalSince1970)
        let reply = Date(timeIntervalSince1970: 1_050)
        state.markViewed(id, at: Date(timeIntervalSince1970: 1_060))
        XCTAssertFalse(state.isUnread(id, lastReplyAt: reply))
        XCTAssertTrue(state.isUnread(id, lastReplyAt: Date(timeIntervalSince1970: 1_070)), "a later reply is unread again")
    }

    func testChatsOlderThanBaselineAreNotUnread() {
        let state = ChatReadState(baseline: baseline.timeIntervalSince1970)
        XCTAssertFalse(state.isUnread(id, lastReplyAt: Date(timeIntervalSince1970: 900)))
        var viewedEarly = state
        viewedEarly.markViewed(id, at: Date(timeIntervalSince1970: 500))
        XCTAssertFalse(viewedEarly.isUnread(id, lastReplyAt: Date(timeIntervalSince1970: 900)))
    }

    /// Empty defaults: app starts at t=1000, a reply lands at t=1050 in the background, and the first
    /// menu lookup happens at t=1100. That reply must be unread.
    func testReplyBetweenStartupAndFirstLookupIsUnread() {
        let suite = "ChatReadStateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        ChatReadState.startup(defaults: defaults, now: Date(timeIntervalSince1970: 1_000))
        let state = ChatReadState.load(defaults: defaults, now: Date(timeIntervalSince1970: 1_100))
        XCTAssertTrue(state.isUnread(id, lastReplyAt: Date(timeIntervalSince1970: 1_050)),
                      "a reply after startup but before the first lookup must stay unread")
    }

    func testStartupKeepsAnExistingBaseline() {
        let suite = "ChatReadStateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(500.0, forKey: ChatReadState.baselineKey)
        ChatReadState.startup(defaults: defaults, now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(ChatReadState.load(defaults: defaults).baseline, 500)
    }
}
