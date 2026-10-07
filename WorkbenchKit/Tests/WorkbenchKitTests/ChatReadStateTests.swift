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

    // MARK: - Unread source: the latest assistant reply, not the chat's updatedDate

    private func t(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }

    func testLastAssistantReplyIgnoresOwnMessagesAndMissingTimestamps() {
        let messages: [ChatReadState.MessageStamp] = [(t(1_010), false), (t(1_050), true), (nil, false)]
        XCTAssertEqual(ChatReadState.lastAssistantReply(messages), t(1_010))
        XCTAssertNil(ChatReadState.lastAssistantReply([(t(1_050), true)]))
        XCTAssertNil(ChatReadState.lastAssistantReply([]))
    }

    /// (1) The user views a reply, then sends their own message: still read.
    func testOwnSendAfterViewingStaysRead() {
        var state = ChatReadState(baseline: baseline.timeIntervalSince1970)
        state.markViewed(id, at: t(1_060))
        let messages: [ChatReadState.MessageStamp] = [(t(1_020), true), (t(1_050), false), (t(1_100), true)]
        XCTAssertFalse(state.isUnread(id, lastReplyAt: ChatReadState.lastAssistantReply(messages)))
    }

    /// (2) A project move or metadata edit bumps updatedDate but adds no assistant message: still read.
    func testMetadataChangeWithoutNewReplyStaysRead() {
        var state = ChatReadState(baseline: baseline.timeIntervalSince1970)
        state.markViewed(id, at: t(1_060))
        let messages: [ChatReadState.MessageStamp] = [(t(1_050), false)]
        // updatedDate is now t(1_200); it is no longer the unread source.
        XCTAssertFalse(state.isUnread(id, lastReplyAt: ChatReadState.lastAssistantReply(messages)))
    }

    /// (3) An assistant reply after the startup baseline, never viewed: unread.
    func testAssistantReplyAfterBaselineIsUnread() {
        let state = ChatReadState(baseline: baseline.timeIntervalSince1970)
        let messages: [ChatReadState.MessageStamp] = [(t(1_040), true), (t(1_050), false)]
        XCTAssertTrue(state.isUnread(id, lastReplyAt: ChatReadState.lastAssistantReply(messages)))
    }

    /// (4) An existing install: baseline set, a partial viewed map without this chat. Its last assistant
    /// reply predates the baseline, even though its updatedDate (a later own send / move) does not: read.
    func testOldChatMissingFromPartialViewedMapStaysRead() {
        let suite = "ChatReadStateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1_000.0, forKey: ChatReadState.baselineKey)
        defaults.set(["other-chat": 1_500.0], forKey: ChatReadState.viewedKey)
        ChatReadState.startup(defaults: defaults, now: t(2_000))
        let state = ChatReadState.load(defaults: defaults, now: t(2_000))
        let messages: [ChatReadState.MessageStamp] = [(t(900), false), (t(1_300), true)]
        XCTAssertFalse(state.isUnread(id, lastReplyAt: ChatReadState.lastAssistantReply(messages)))
        XCTAssertTrue(state.isUnread(id, lastReplyAt: t(1_300)), "the old updatedDate-style source would light it up")
    }

    // MARK: - Reactivation

    /// Every guard combination: only active + visible + Chats tab + a selected chat marks that chat viewed.
    func testChatToMarkOnActivationGuards() {
        for active in [false, true] {
            for visible in [false, true] {
                for chats in [false, true] {
                    for selected in [nil, "chat-1"] as [String?] {
                        let got = ChatReadState.chatToMarkOnActivation(
                            isActive: active, windowVisible: visible, chatsTabShown: chats, selectedChat: selected)
                        let want: String? = (active && visible && chats) ? selected : nil
                        XCTAssertEqual(got, want, "active=\(active) visible=\(visible) chats=\(chats) selected=\(String(describing: selected))")
                    }
                }
            }
        }
    }

    // A reply that finishes is read only if the user can actually see that chat.
    private func finished(_ finished: String = "a", active: Bool = true, visible: Bool = true,
                          chats: Bool = true, selected: String? = "a") -> Bool {
        ChatReadState.shouldMarkFinishedChatViewed(
            finishedChat: finished, isActive: active, windowVisible: visible,
            chatsTabShown: chats, selectedChat: selected)
    }

    func testFinishedReplyWindowClosedNotMarked() { XCTAssertFalse(finished(visible: false)) }
    func testFinishedReplyWindowMinimizedNotMarked() {
        let isVisible = true, isMiniaturized = true
        XCTAssertFalse(finished(visible: isVisible && !isMiniaturized))
    }
    func testFinishedReplySettingsOnlyActiveNotMarked() { XCTAssertFalse(finished(active: true, visible: false)) }
    func testFinishedReplyAppInactiveNotMarked() { XCTAssertFalse(finished(active: false)) }
    func testFinishedReplyJobsTabNotMarked() { XCTAssertFalse(finished(chats: false)) }
    func testFinishedReplyDifferentChatNotMarked() { XCTAssertFalse(finished(selected: "b")) }
    func testFinishedReplyNoChatSelectedNotMarked() { XCTAssertFalse(finished(selected: nil)) }
    func testFinishedReplyAllConditionsMarked() { XCTAssertTrue(finished()) }
}
