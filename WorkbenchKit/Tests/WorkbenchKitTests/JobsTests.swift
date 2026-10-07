import XCTest
@testable import WorkbenchKit

final class JobsTests: XCTestCase {
    private func record(_ id: String, _ status: JobStatus) -> JobRecord {
        JobRecord(id: id, project: "Scout", workflow: .peer, status: status, title: id, model: nil, host: nil, taskPath: nil, artifactPath: nil, summary: "", output: "", updatedAt: Date(timeIntervalSince1970: 0), eventCount: 0)
    }

    func testDiffReportsNewAndChangedOnly() {
        let old = [record("a", .running), record("b", .complete)]
        let new = [record("a", .complete), record("b", .complete), record("c", .failed)]
        let changes = JobFeed.diff(old: old, new: new)
        XCTAssertEqual(changes.map(\.record.id), ["a", "c"])
        XCTAssertEqual(changes[0].previousStatus, .running)
        XCTAssertNil(changes[1].previousStatus)
        XCTAssertTrue(JobFeed.diff(old: new, new: new).isEmpty)
    }

    func testTaskTitleFromYamlThenMarkdown() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(JobFeed.taskTitle(taskURL: dir))
        try "# Fix the login bug\n\nBody".write(to: dir.appendingPathComponent("spec.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(JobFeed.taskTitle(taskURL: dir), "Fix the login bug")
        try "id: 1\ntitle: \"Ship the feed\"\n".write(to: dir.appendingPathComponent("task.yaml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(JobFeed.taskTitle(taskURL: dir), "Ship the feed")
        let long = String(repeating: "x", count: 120)
        try "title: \(long)\n".write(to: dir.appendingPathComponent("task.yaml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(JobFeed.taskTitle(taskURL: dir), String(repeating: "x", count: 90) + "...")
    }

    func testHosakaArtifactRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let task = root.appendingPathComponent("tasks/done/T-1")
        let evidence = task.appendingPathComponent("evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "title: Demo task\n".write(to: task.appendingPathComponent("task.yaml"), atomically: true, encoding: .utf8)
        try #"{"verdict":"pass","reason":"ok","model":"ornith"}"#.write(to: evidence.appendingPathComponent("helga-verdict.json"), atomically: true, encoding: .utf8)
        let records = JobFeed.hosakaArtifactRecords(project: "Scout", root: root.path)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, "Scout:helga:T-1")
        XCTAssertEqual(records[0].title, "Demo task")
        XCTAssertEqual(records[0].status, .complete)
        XCTAssertEqual(records[0].summary, "ok")
    }

    func testCommandArgumentParsing() {
        let cmd = "node agentic-coding-bench.mjs --out /tmp/run --models=a,b"
        XCTAssertEqual(JobFeed.commandArgument(after: "--out", in: cmd), "/tmp/run")
        XCTAssertEqual(JobFeed.commandArgument(after: "--models", in: cmd), "a,b")
    }

    func testRLResearchHelpers() {
        XCTAssertEqual(JobFeed.rlResearchRunBase("pi-api.2026.main.md"), "pi-api.2026")
        XCTAssertEqual(JobFeed.rlResearchRunBase("x.2026.status.json"), "x.2026")
        XCTAssertNil(JobFeed.rlResearchRunBase("plain.md"))
        XCTAssertEqual(JobFeed.rlResearchTitle(from: "pi-api-rl.2026"), "PI API RL")
    }
}

final class JobFeedCleaningTests: XCTestCase {
    private func record(_ id: String, status: JobStatus, age: TimeInterval, task: String? = nil) -> JobRecord {
        JobRecord(id: id, project: "Scout", workflow: .helga, status: status, title: id, model: nil, host: nil,
                  taskPath: task, artifactPath: nil, summary: "Helga investigation started", output: "",
                  updatedAt: Date(timeIntervalSinceNow: -age), eventCount: 1)
    }

    func testBenchRunsHiddenByDefault() {
        let records = [record("a", status: .complete, age: 10, task: "/Users/x/.hosaka/.bench-runs/t/run-1"),
                       record("b", status: .complete, age: 10, task: "/Users/x/scout/tasks/done/t")]
        XCTAssertEqual(JobFeed.clean(records, includeBenchRuns: false, staleAfter: 3600, now: Date()).map(\.id), ["b"])
        XCTAssertEqual(JobFeed.clean(records, includeBenchRuns: true, staleAfter: 3600, now: Date()).count, 2)
    }

    func testOldRunningJobsBecomeStale() {
        let cleaned = JobFeed.clean([record("old", status: .running, age: 7200), record("new", status: .running, age: 60)],
                                    includeBenchRuns: false, staleAfter: 3600, now: Date())
        XCTAssertEqual(cleaned.first { $0.id == "old" }?.status, .unknown)
        XCTAssertTrue(cleaned.first { $0.id == "old" }?.summary.hasPrefix("No update for 2h") == true)
        XCTAssertEqual(cleaned.first { $0.id == "new" }?.status, .running)
    }

    func testFolderPreviewListsFilesAndLogTail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "line one\nfinal verdict: clean".write(to: dir.appendingPathComponent("helga.log"), atomically: true, encoding: .utf8)
        let preview = try XCTUnwrap(JobFeed.folderPreview(path: dir.path))
        XCTAssertTrue(preview.contains("helga.log"))
        XCTAssertTrue(preview.contains("final verdict: clean"))
    }
}
