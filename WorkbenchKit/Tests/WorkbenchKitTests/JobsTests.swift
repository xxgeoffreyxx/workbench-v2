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

    func testSortIsStrictlyNewestFirstThenTitle() {
        func r(_ id: String, _ project: String, _ wf: JobWorkflow, _ status: JobStatus, _ t: Double) -> JobRecord {
            JobRecord(id: id, project: project, workflow: wf, status: status, title: id, model: nil, host: nil, taskPath: nil,
                      artifactPath: nil, summary: "", output: "", updatedAt: Date(timeIntervalSince1970: t), eventCount: 0)
        }
        let records = [r("old-scout-running", "Scout", .background, .running, 10), r("b-tie", "RL", .peer, .complete, 50),
                       r("a-tie", "ThriveOS", .helga, .complete, 50), r("newest-other", "Zeta", .peer, .failed, 100)]
        XCTAssertEqual(JobFeed.sortedByTime(records).map(\.id), ["newest-other", "a-tie", "b-tie", "old-scout-running"])
    }

    func testHosakaRunRecordsFromRunsRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let run = root.appendingPathComponent("scout/adhoc-1")
        let evidence = run.appendingPathComponent("evidence")
        try FileManager.default.createDirectory(at: evidence.appendingPathComponent("helga-diagnostics"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Requirements Contract: Fix the feed\n\nBody".write(to: run.appendingPathComponent("requirements.md"), atomically: true, encoding: .utf8)
        try #"{"verdict":"REJECT","reason":"loops","turns":40,"total_tokens":426927,"elapsed_seconds":228.0,"timestamp":"2026-09-30T02:24:24Z"}"#
            .write(to: evidence.appendingPathComponent("helga-verdict.json"), atomically: true, encoding: .utf8)
        let log = String(repeating: "early noise\n", count: 3000) + "FINAL LINE OF LOG"
        try log.write(to: evidence.appendingPathComponent("helga-run.log"), atomically: true, encoding: .utf8)
        let turns = [
            #"{"turn":0,"prompt_tokens":4000,"completion_tokens":90,"response":"I will look around first."}"#,
            #"{"turn":1,"prompt_tokens":4621,"completion_tokens":41,"response":"```\n{\"action\":\"execute\",\"command\":\"cat a.js\"}\n```"}"#,
        ].joined(separator: "\n")
        try turns.write(to: evidence.appendingPathComponent("helga-diagnostics/model-turns.jsonl"), atomically: true, encoding: .utf8)
        try #"{"verdict":"clean","agents_dispatched":3,"timestamp":"2026-09-30T03:00:00Z"}"#
            .write(to: evidence.appendingPathComponent("code-review-result.json"), atomically: true, encoding: .utf8)

        let records = JobFeed.hosakaRunRecords(runsRoot: root.path)
        let helga = try XCTUnwrap(records.first { $0.workflow == .helga })
        let peer = try XCTUnwrap(records.first { $0.workflow == .peer })
        XCTAssertEqual(helga.id, "Scout:helga:adhoc-1")
        XCTAssertEqual(helga.title, "Scout: Requirements Contract: Fix the feed")
        XCTAssertEqual(helga.status, .failed)
        XCTAssertEqual(helga.updatedAt, ISO8601DateFormatter().date(from: "2026-09-30T02:24:24Z"))
        XCTAssertTrue(helga.summary.contains("loops"))
        XCTAssertTrue(helga.summary.contains("40 turns"))
        XCTAssertTrue(helga.summary.contains("426927 tokens"))
        XCTAssertTrue(helga.summary.contains("228s"))
        XCTAssertTrue(helga.output.contains("\"verdict\":\"REJECT\""))
        XCTAssertTrue(helga.output.contains("FINAL LINE OF LOG"), "log tail must be kept, not the head")
        XCTAssertTrue(helga.output.contains("turn 1 · prompt 4621 · completion 41 · execute: cat a.js"))
        XCTAssertTrue(helga.output.contains("turn 0 · prompt 4000 · completion 90 · I will look around first."))
        XCTAssertEqual(peer.id, "Scout:peer:adhoc-1")
        XCTAssertEqual(peer.updatedAt, ISO8601DateFormatter().date(from: "2026-09-30T03:00:00Z"))
    }

    func testHelgaTimestampFallsBackToEventsThenMtime() throws {
        let run = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: run.appendingPathComponent("evidence"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: run) }
        let json = run.appendingPathComponent("evidence/helga-verdict.json")
        try #"{"verdict":"PASS"}"#.write(to: json, atomically: true, encoding: .utf8)
        try [#"{"ts":"2026-09-29T01:00:00Z","event":"approved"}"#,
             #"{"ts":"2026-09-29T02:00:00Z","event":"reviewer_waived","reviewer":"qa_helga"}"#,
             #"{"ts":"2026-09-29T03:00:00Z","event":"deploy"}"#].joined(separator: "\n")
            .write(to: run.appendingPathComponent("events.ndjson"), atomically: true, encoding: .utf8)
        let record = JobFeed.helgaRecord(project: "Scout", taskName: "r", title: "t", taskURL: run, jsonURL: json,
                                         logURL: run.appendingPathComponent("evidence/helga-run.log"))
        XCTAssertEqual(record.updatedAt, ISO8601DateFormatter().date(from: "2026-09-29T02:00:00Z"))
        try FileManager.default.removeItem(at: run.appendingPathComponent("events.ndjson"))
        let fallback = JobFeed.helgaRecord(project: "Scout", taskName: "r", title: "t", taskURL: run, jsonURL: json,
                                           logURL: run.appendingPathComponent("evidence/helga-run.log"))
        XCTAssertEqual(fallback.updatedAt, JobFeed.modificationDate([json, run]))
    }

    func testEventsDoNotOverwriteEvidenceTitleSummaryOrOutput() {
        let evidenceTime = Date(timeIntervalSince1970: 1_000)
        let artifact = JobRecord(id: "Scout:helga:run-1", project: "Scout", workflow: .helga, status: .complete,
                                 title: "Scout: Requirements Contract: Fix the feed", model: nil, host: nil, taskPath: "/x",
                                 artifactPath: "/x/evidence/helga-verdict.json", summary: "ok · 40 turns",
                                 output: "rich output", updatedAt: evidenceTime, eventCount: 0)
        func event(_ status: JobStatus, _ t: Double, _ summary: String) -> JobEvent {
            JobEvent(jobID: "Scout:helga:run-1", timestamp: Date(timeIntervalSince1970: t), project: "Scout",
                     workflow: .helga, status: status, title: "Requirements Contract", summary: summary)
        }
        let finished = JobFeed.merge(artifacts: [artifact], events: [event(.running, 900, "started"), event(.complete, 1_000, "Helga verdict: PASS")])
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished[0].title, "Scout: Requirements Contract: Fix the feed")
        XCTAssertEqual(finished[0].summary, "ok · 40 turns")
        XCTAssertEqual(finished[0].output, "rich output")
        XCTAssertEqual(finished[0].status, .complete)
        let rerun = JobFeed.merge(artifacts: [artifact], events: [event(.running, 2_000, "Helga investigation started")])
        XCTAssertEqual(rerun[0].status, .running)
        XCTAssertEqual(rerun[0].summary, "Helga investigation started")
        XCTAssertEqual(rerun[0].title, "Scout: Requirements Contract: Fix the feed")
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

final class ShortAgeTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")!
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func age(_ seconds: TimeInterval) -> String {
        ShortAge.text(for: now.addingTimeInterval(-seconds), now: now, calendar: utc, locale: Locale(identifier: "en_US"))
    }

    func testBoundaries() {
        XCTAssertEqual(age(0), "now")
        XCTAssertEqual(age(59), "now")
        XCTAssertEqual(age(-30), "now", "future times read as now")
        XCTAssertEqual(age(60), "1m ago")
        XCTAssertEqual(age(5 * 60), "5m ago")
        XCTAssertEqual(age(3599), "59m ago")
        XCTAssertEqual(age(3600), "1h ago")
        XCTAssertEqual(age(5 * 3600), "5h ago")
        XCTAssertEqual(age(86_399), "23h ago")
        XCTAssertEqual(age(86_400), "1d ago")
        XCTAssertEqual(age(3 * 86_400), "3d ago")
        XCTAssertEqual(age(7 * 86_400 - 1), "6d ago")
        XCTAssertEqual(age(7 * 86_400), "Sep 23")
        XCTAssertEqual(age(300 * 86_400), "Dec 4, 2025")
    }
}

final class JobEventResolutionTests: XCTestCase {
    private var root: URL!
    private var runs: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = base.appendingPathComponent("scout")
        runs = base.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func makeTask(_ relative: String, under base: URL, verdict: String = "PASS") throws {
        let evidence = base.appendingPathComponent(relative).appendingPathComponent("evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try "title: Real task title\n".write(to: evidence.deletingLastPathComponent().appendingPathComponent("task.yaml"), atomically: true, encoding: .utf8)
        try #"{"verdict":"\#(verdict)","reason":"from disk","turns":7}"#.write(to: evidence.appendingPathComponent("helga-verdict.json"), atomically: true, encoding: .utf8)
        try "log body\nLAST LOG LINE".write(to: evidence.appendingPathComponent("helga-run.log"), atomically: true, encoding: .utf8)
    }

    private func event(task: String?, artifact: String? = nil, summary: String = "Helga verdict: PASS") -> JobEvent {
        JobEvent(jobID: "Scout:helga:803b", timestamp: Date(timeIntervalSince1970: 5), project: "Scout", workflow: .helga,
                 status: .complete, title: "Requirements Contract", taskPath: task, artifactPath: artifact, summary: summary)
    }

    private func merged(_ e: JobEvent) -> JobRecord {
        JobFeed.merge(artifacts: [], events: [e], projectRoots: ["scout": root], runsRoot: runs.path)[0]
    }

    func testRelativeEventPathResolvesAgainstProjectRoot() throws {
        try makeTask("tasks/code-complete/803b", under: root)
        let record = merged(event(task: "tasks/code-complete/803b", artifact: "tasks/code-complete/803b/evidence/helga-verdict.json"))
        XCTAssertTrue(record.output.contains("LAST LOG LINE"))
        XCTAssertEqual(record.title, "Real task title")
        XCTAssertTrue(record.summary.contains("from disk"))
    }

    func testStaleStagePathFindsTaskInItsCurrentStage() throws {
        try makeTask("tasks/done/803b", under: root)
        let record = merged(event(task: "tasks/code-complete/803b"))
        XCTAssertEqual(record.taskPath, root.appendingPathComponent("tasks/done/803b").path)
        XCTAssertTrue(record.output.contains("LAST LOG LINE"))
    }

    func testAdhocRunFoundUnderRunsRoot() throws {
        try makeTask("scout/803b", under: runs)
        let record = merged(event(task: "/gone/elsewhere/803b"))
        XCTAssertTrue(record.output.contains("LAST LOG LINE"))
    }

    func testScannedOutputWinsOverEmptyEventOutput() throws {
        let scanned = JobRecord(id: "Scout:helga:803b", project: "Scout", workflow: .helga, status: .complete, title: "t",
                                model: nil, host: nil, taskPath: nil, artifactPath: nil, summary: "s", output: "scanned output",
                                updatedAt: Date(timeIntervalSince1970: 5), eventCount: 0)
        let record = JobFeed.merge(artifacts: [scanned], events: [event(task: nil)], projectRoots: ["scout": root], runsRoot: runs.path)[0]
        XCTAssertEqual(record.output, "scanned output")
    }

    func testMissingEvidenceStillShowsEventDetails() {
        let record = merged(event(task: "tasks/code-complete/nowhere", summary: "Helga verdict: REJECT"))
        XCTAssertFalse(record.output.isEmpty)
        XCTAssertTrue(record.output.contains("Helga verdict: REJECT"))
        XCTAssertTrue(record.output.contains("tasks/code-complete/nowhere"))
    }
}

final class FixtureAndDedupeTests: XCTestCase {
    private func rec(_ id: String, task: String?) -> JobRecord {
        JobRecord(id: id, project: "Scout", workflow: .helga, status: .complete, title: id, model: nil, host: nil, taskPath: task,
                  artifactPath: nil, summary: "", output: "x", updatedAt: Date(), eventCount: 0)
    }

    func testTempDirFixturesHidden() {
        let records = [rec("helga-256k:helga:pass-task", task: "/var/folders/w4/abc/T/tmp.X/pass-task"),
                       rec("f2", task: "/private/tmp/tmp.Y/reject-task"),
                       rec("real", task: "/Users/x/scout/tasks/done/803b")]
        XCTAssertEqual(JobFeed.clean(records, includeBenchRuns: false, staleAfter: 3600, now: Date()).map(\.id), ["real"])
    }

    func testEventWithDifferentCaseIDMergesIntoScannedRecord() {
        let scanned = JobRecord(id: "Scout:peer:adhoc-1", project: "Scout", workflow: .peer, status: .complete,
                                title: "Scout: Real", model: nil, host: nil, taskPath: "/r/scout/adhoc-1", artifactPath: nil,
                                summary: "s", output: "o", updatedAt: Date(timeIntervalSince1970: 10), eventCount: 0)
        let event = JobEvent(jobID: "scout:peer:adhoc-1", timestamp: Date(timeIntervalSince1970: 5), project: "scout",
                             workflow: .peer, status: .complete, title: "Requirements Contract", taskPath: "/r/scout/adhoc-1")
        let merged = JobFeed.merge(artifacts: [scanned], events: [event], projectRoots: [:], runsRoot: "/nonexistent")
        XCTAssertEqual(merged.map(\.id), ["Scout:peer:adhoc-1"])
        XCTAssertEqual(merged[0].title, "Scout: Real")
        XCTAssertEqual(merged[0].eventCount, 1)
    }
}
