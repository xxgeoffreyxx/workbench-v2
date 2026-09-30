import XCTest
@testable import WorkbenchKit

final class MenuFeedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)

    private func job(_ id: String, _ workflow: JobWorkflow, _ status: JobStatus, ago: TimeInterval) -> JobRecord {
        JobRecord(id: id, project: "Scout", workflow: workflow, status: status, title: "T \(id)", model: nil, host: nil,
                  taskPath: nil, artifactPath: nil, summary: "", output: "", updatedAt: now.addingTimeInterval(-ago), eventCount: 0)
    }

    private func chat(_ name: String, ago: TimeInterval, busy: Bool = false, unread: Bool = false) -> MenuFeed.Chat {
        MenuFeed.Chat(id: UUID(), title: name, updatedAt: now.addingTimeInterval(-ago), busy: busy, unread: unread)
    }

    func testOnlyRunningJobsAndActiveChats() {
        let items = MenuFeed.items(
            jobs: [job("done", .helga, .complete, ago: 1), job("failed", .peer, .failed, ago: 2), job("run", .peer, .running, ago: 30),
                   job("stale", .helga, .unknown, ago: 3)],
            chats: [chat("idle", ago: 1), chat("busy", ago: 50, busy: true), chat("unread", ago: 5, unread: true)],
            now: now)
        XCTAssertEqual(Set(items.map(\.title)), ["T run", "unread"])
    }

    func testOrderingRunningFirstThenUnreadNewestFirst() {
        let items = MenuFeed.items(
            jobs: [job("old-run", .peer, .running, ago: 900), job("new-run", .helga, .running, ago: 60)],
            chats: [chat("unread", ago: 1, unread: true), chat("older-unread", ago: 300, unread: true)],
            now: now)
        XCTAssertEqual(items.map(\.title), ["T new-run", "T old-run", "unread", "older-unread"])
        XCTAssertEqual(items.map(\.marker), [.running, .running, .unread, .unread])
    }

    func testEmptyWhenNothingRunning() {
        XCTAssertTrue(MenuFeed.build(jobs: [job("d", .helga, .complete, ago: 1)], chats: [chat("c", ago: 1)], now: now).items.isEmpty)
    }

    func testLimitsToFifteenAndFlagsMore() {
        let chats = (0..<20).map { chat("c\($0)", ago: TimeInterval($0), unread: true) }
        let feed = MenuFeed.build(jobs: [], chats: chats, now: now)
        XCTAssertEqual(feed.items.count, 15)
        XCTAssertTrue(feed.hasMore)
        XCTAssertFalse(MenuFeed.build(jobs: [], chats: Array(chats.prefix(3)), now: now).hasMore)
    }

    func testJobDetailShowsWorkflowAndElapsed() {
        XCTAssertEqual(MenuFeed.items(jobs: [job("r", .helga, .running, ago: 300)], chats: [], now: now)[0].detail, "Helga · 5m")
    }

    func testChatsAppearOnlyWithAnUnreadReply() {
        let generating = chat("generating", ago: 1, busy: true)
        let recent = chat("recent", ago: 1)
        let waiting = chat("waiting", ago: 1, unread: true)
        let generatingWithEarlierReply = chat("both", ago: 2, busy: true, unread: true)
        let items = MenuFeed.items(jobs: [], chats: [generating, recent, waiting, generatingWithEarlierReply], now: now)
        XCTAssertEqual(Set(items.map(\.title)), ["waiting", "both"])
        XCTAssertTrue(items.allSatisfy { $0.marker == .unread })
        // Once opened (no longer unread) it's gone.
        XCTAssertTrue(MenuFeed.items(jobs: [], chats: [chat("waiting", ago: 1)], now: now).isEmpty)
    }

    func testUnreadRule() {
        let viewed = Date(timeIntervalSince1970: 50)
        XCTAssertTrue(MenuFeed.isUnread(lastReplyAt: Date(timeIntervalSince1970: 60), lastViewedAt: viewed))
        XCTAssertFalse(MenuFeed.isUnread(lastReplyAt: Date(timeIntervalSince1970: 40), lastViewedAt: viewed))
        XCTAssertFalse(MenuFeed.isUnread(lastReplyAt: Date(timeIntervalSince1970: 1), lastViewedAt: nil))
    }
}

final class MenuLayoutTests: XCTestCase {
    func testMenuOrder() {
        XCTAssertEqual(MenuLayout.order, [.running, .separator, .models, .refreshStatus, .separator, .open, .settings, .quit])
        XCTAssertFalse(MenuLayout.order.contains(.newChat))
        XCTAssertFalse(MenuLayout.order.contains(.quickChat))
    }

    func testOpenIsTitledOpenWithCommandO() {
        XCTAssertEqual(MenuLayout.Slot.open.title, "Open")
        XCTAssertEqual(MenuLayout.Slot.open.key, "o")
    }
}
