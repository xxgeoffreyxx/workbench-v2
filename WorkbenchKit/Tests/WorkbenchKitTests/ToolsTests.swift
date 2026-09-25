import XCTest
@testable import WorkbenchKit

final class FakeApprover: ToolApprover, @unchecked Sendable {
    private let lock = NSLock()
    let decision: ApprovalDecision
    private(set) var requests: [ApprovalRequest] = []
    init(_ decision: ApprovalDecision) { self.decision = decision }
    func approve(_ request: ApprovalRequest) async -> ApprovalDecision {
        lock.withLock { requests.append(request) }
        return decision
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
}

func makeTempDir(_ name: String = "wbtest") -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class ToolsTests: XCTestCase {
    var root: URL!
    var outside: URL!
    var home: URL!

    override func setUp() {
        root = makeTempDir("proj")
        outside = makeTempDir("outside")
        home = makeTempDir("home")
        try! "hello\nworld\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try! "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
    }

    func runtime(_ approver: FakeApprover, project: URL? = nil) -> ToolRuntime {
        ToolRuntime(projectRoot: project ?? root, approver: approver,
                    skills: SkillCatalog(homeDirectory: home, projectRoot: project ?? root),
                    approvals: ApprovalStore(fileURL: home.appendingPathComponent("approvals.json")))
    }

    func testConfinementRejectsDotDot() {
        XCTAssertNotNil(PathConfinement.confined("a.txt", root: root))
        XCTAssertNotNil(PathConfinement.confined("new/dir/file.txt", root: root))
        XCTAssertNil(PathConfinement.confined("../x.txt", root: root))
        XCTAssertNil(PathConfinement.confined("sub/../../x.txt", root: root))
        XCTAssertNil(PathConfinement.confined("/etc/passwd", root: root))
    }

    func testConfinementRejectsSymlinkEscape() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertNil(PathConfinement.confined("link/secret.txt", root: root))
        XCTAssertNil(PathConfinement.confined("link/newfile.txt", root: root))
    }

    func testReadFileConfined() async throws {
        let rt = runtime(FakeApprover(.approve))
        let ok = await rt.run(name: "wb_read_file", argumentsJSON: #"{"path":"a.txt"}"#)
        XCTAssertTrue(ok.contains("1\thello"))
        let bad = await rt.run(name: "wb_read_file", argumentsJSON: #"{"path":"../\#(outside.lastPathComponent)/secret.txt"}"#)
        XCTAssertTrue(bad.contains("outside"), bad)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let sym = await rt.run(name: "wb_read_file", argumentsJSON: #"{"path":"link/secret.txt"}"#)
        XCTAssertFalse(sym.contains("secret\n") || sym.contains("\tsecret"), sym)
    }

    func testReadAllowedFromSkillDirectory() async throws {
        let skillDir = home.appendingPathComponent(".claude/skills/demo")
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: d\n---\nbody".write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "ref content".write(to: skillDir.appendingPathComponent("ref.md"), atomically: true, encoding: .utf8)
        let rt = runtime(FakeApprover(.approve))
        let out = await rt.run(name: "wb_read_file", argumentsJSON: "{\"path\":\"\(skillDir.appendingPathComponent("ref.md").path)\"}")
        XCTAssertTrue(out.contains("ref content"), out)
    }

    func testNoProject() async {
        let rt = ToolRuntime(projectRoot: nil, approver: FakeApprover(.approve), skills: SkillCatalog(homeDirectory: home),
                             approvals: ApprovalStore(fileURL: home.appendingPathComponent("a.json")))
        let out = await rt.run(name: "wb_run_command", argumentsJSON: #"{"command":"ls"}"#)
        XCTAssertEqual(out, ToolRuntime.noProjectMessage)
        let list = await rt.run(name: "wb_list_files", argumentsJSON: "{}")
        XCTAssertEqual(list, ToolRuntime.noProjectMessage)
    }

    func testEvidenceGuardPaths() {
        XCTAssertTrue(EvidenceGuard.isProtected(path: "tasks/doing/t1/evidence/x.json"))
        XCTAssertTrue(EvidenceGuard.isProtected(path: "/abs/evidence/y"))
        XCTAssertTrue(EvidenceGuard.isProtected(path: "QA-RESULT.json"))
        XCTAssertTrue(EvidenceGuard.isProtected(path: "a/b/monitor-result.json"))
        XCTAssertTrue(EvidenceGuard.isProtected(path: "code-review-result.json"))
        XCTAssertFalse(EvidenceGuard.isProtected(path: "src/evidence.swift"))
        XCTAssertFalse(EvidenceGuard.isProtected(path: "README.md"))
    }

    func testEvidenceGuardCommands() {
        XCTAssertTrue(EvidenceGuard.commandWritesEvidence(#"echo '{"pass":true}' > tasks/t/evidence/QA-RESULT.json"#))
        XCTAssertTrue(EvidenceGuard.commandWritesEvidence("cat x | tee QA-RESULT.json"))
        XCTAssertTrue(EvidenceGuard.commandWritesEvidence("cp /tmp/r.json tasks/t/production-verification.json"))
        XCTAssertTrue(EvidenceGuard.commandWritesEvidence("mv out.json evidence/monitor-result.json"))
        XCTAssertTrue(EvidenceGuard.commandWritesEvidence("echo hi >> tasks/x/evidence/log.txt"))
        XCTAssertFalse(EvidenceGuard.commandWritesEvidence("cat tasks/t/evidence/QA-RESULT.json"))
        XCTAssertFalse(EvidenceGuard.commandWritesEvidence("bash ~/.hosaka/scripts/hosaka-gate-plan.sh"))
        XCTAssertFalse(EvidenceGuard.commandWritesEvidence("echo hi > out.txt"))
    }

    func testEvidenceGuardInTools() async {
        let approver = FakeApprover(.approve)
        let rt = runtime(approver)
        let w = await rt.run(name: "wb_write_file", argumentsJSON: #"{"path":"tasks/t/evidence/QA-RESULT.json","content":"{}"}"#)
        XCTAssertTrue(w.contains("Hosaka owner scripts"), w)
        let w2 = await rt.run(name: "wb_write_file", argumentsJSON: #"{"path":"localhost-verification.json","content":"{}"}"#)
        XCTAssertTrue(w2.contains("Refused"), w2)
        let patch = "--- a/evidence/x.json\n+++ b/evidence/x.json\n@@ -0,0 +1 @@\n+{}\n"
        let p = await rt.run(name: "wb_apply_patch", argumentsJSON: String(decoding: try! JSONSerialization.data(withJSONObject: ["patch": patch]), as: UTF8.self))
        XCTAssertTrue(p.contains("Refused"), p)
        let c = await rt.run(name: "wb_run_command", argumentsJSON: #"{"command":"echo x > evidence/QA-RESULT.json"}"#)
        XCTAssertTrue(c.contains("owner script"), c)
        XCTAssertEqual(approver.count, 0, "evidence refusals must happen before asking the user")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("evidence").path))
    }

    func testWriteRequiresApproval() async {
        let denied = runtime(FakeApprover(.deny))
        let d = await denied.run(name: "wb_write_file", argumentsJSON: #"{"path":"b.txt","content":"x"}"#)
        XCTAssertTrue(d.contains("denied"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
        let approver = FakeApprover(.approve)
        let ok = await runtime(approver).run(name: "wb_write_file", argumentsJSON: #"{"path":"sub/b.txt","content":"x"}"#)
        XCTAssertTrue(ok.hasPrefix("Wrote"), ok)
        XCTAssertEqual(approver.requests.first?.kind, .writeFile)
        let escape = await runtime(approver).run(name: "wb_write_file", argumentsJSON: #"{"path":"../evil.txt","content":"x"}"#)
        XCTAssertTrue(escape.contains("outside"))
    }

    func testApplyPatch() async {
        let approver = FakeApprover(.approve)
        let patch = "```diff\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n hello\n-world\n+there\n```"
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: ["patch": patch]), as: UTF8.self)
        let out = await runtime(approver).run(name: "wb_apply_patch", argumentsJSON: json)
        XCTAssertTrue(out.hasPrefix("Patch applied"), out)
        XCTAssertEqual(try? String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8), "hello\nthere\n")
        XCTAssertEqual(approver.requests.first?.kind, .patch)
    }

    func testRunCommandAndAlwaysAllowPersistence() async throws {
        let approver = FakeApprover(.alwaysAllow)
        let rt = runtime(approver)
        let out = await rt.run(name: "wb_run_command", argumentsJSON: #"{"command":"ls -a"}"#)
        XCTAssertTrue(out.contains("Exit code: 0") && out.contains("a.txt"), out)
        XCTAssertEqual(approver.count, 1)
        _ = await rt.run(name: "wb_run_command", argumentsJSON: #"{"command":"ls -1"}"#)
        XCTAssertEqual(approver.count, 1, "always-allowed prefix should not prompt again")
        // Chained commands still prompt.
        _ = await rt.run(name: "wb_run_command", argumentsJSON: #"{"command":"ls; rm -rf x"}"#)
        XCTAssertEqual(approver.count, 2)

        // Persisted to disk, keyed by project path; a fresh store sees it.
        let store = ApprovalStore(fileURL: home.appendingPathComponent("approvals.json"))
        XCTAssertTrue(store.isAllowed(command: "ls -l", projectKey: rt.projectRoot!.path))
        XCTAssertFalse(store.isAllowed(command: "ls -l", projectKey: "/some/other/project"))
        let data = try Data(contentsOf: home.appendingPathComponent("approvals.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: [String]]
        XCTAssertEqual(json?[rt.projectRoot!.path], ["ls"])
    }

    func testCommandPrefix() {
        XCTAssertEqual(ApprovalStore.commandPrefix("git status --short"), "git status")
        XCTAssertEqual(ApprovalStore.commandPrefix("npm run test"), "npm run")
        XCTAssertEqual(ApprovalStore.commandPrefix("ls -la"), "ls")
        XCTAssertEqual(ApprovalStore.commandPrefix("echo hi"), "echo hi")
    }

    func testRunCommandExitCodeAndCwd() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let rt = runtime(FakeApprover(.approve))
        let out = await rt.run(name: "wb_run_command", argumentsJSON: #"{"command":"pwd; exit 3","cwd":"sub"}"#)
        XCTAssertTrue(out.contains("Exit code: 3") && out.contains("/sub"), out)
        let bad = await rt.run(name: "wb_run_command", argumentsJSON: #"{"command":"pwd","cwd":"../"}"#)
        XCTAssertTrue(bad.contains("outside"))
    }

    func testSpecsAndPatchExtraction() {
        let rt = runtime(FakeApprover(.approve))
        let names = rt.specs(includeSkills: true).map(\.name)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("wb_") })
        XCTAssertTrue(names.contains("wb_use_skill"))
        XCTAssertFalse(rt.specs(includeSkills: false).map(\.name).contains("wb_use_skill"))
        XCTAssertTrue(rt.handles("wb_run_command"))
        XCTAssertFalse(rt.handles("run_command"))
        let def = rt.specs(includeSkills: false)[0].openAIDefinition
        XCTAssertEqual(def["type"] as? String, "function")
        XCTAssertNotNil((def["function"] as? [String: Any])?["parameters"] as? [String: Any])

        let reply = "text\n```diff\nfirst\n```\nmore\n```patch\n--- a/x\n+++ b/x\n```\nend"
        XCTAssertEqual(ProjectContext.extractPatchBlock(from: reply), "--- a/x\n+++ b/x")
        XCTAssertNil(ProjectContext.extractPatchBlock(from: "no patch here"))
        XCTAssertEqual(EvidenceGuard.patchPaths("diff --git a/src/x.swift b/src/x.swift\n--- a/src/x.swift\n+++ b/src/x.swift\n"), ["src/x.swift"])
    }

    func testOverview() async {
        let out = await ProjectContext.overview(root: root, query: "what is in a.txt")
        XCTAssertTrue(out.contains("PROJECT OVERVIEW"))
        XCTAssertTrue(out.contains("a.txt"))
    }
}
