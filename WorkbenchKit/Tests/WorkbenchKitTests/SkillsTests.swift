import XCTest
@testable import WorkbenchKit

final class SkillsTests: XCTestCase {
    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testFrontMatterParsing() {
        let text = "---\nname: qa\ndescription: \"Run QA: fully\"\nother: 'x'\nlong: >\n  folded one\n  two\n---\n# Title\nBody"
        let (fields, body) = FrontMatter.parse(text)
        XCTAssertEqual(fields["name"], "qa")
        XCTAssertEqual(fields["description"], "Run QA: fully")
        XCTAssertEqual(fields["other"], "x")
        XCTAssertEqual(fields["long"], "folded one two")
        XCTAssertEqual(body, "# Title\nBody")
        let none = FrontMatter.parse("# Heading only\ntext")
        XCTAssertTrue(none.fields.isEmpty)
        XCTAssertEqual(FrontMatter.firstHeading(none.body), "Heading only")
    }

    func makeCatalog() throws -> (SkillCatalog, URL, URL) {
        let home = makeTempDir("home"), project = makeTempDir("proj")
        try write("---\nname: shared\ndescription: user version\n---\nuser body", home.appendingPathComponent(".claude/skills/shared/SKILL.md"))
        try write("---\nname: shared\ndescription: codex version\n---\ncodex", home.appendingPathComponent(".codex/skills/shared/SKILL.md"))
        try write("---\nname: shared\ndescription: project version\n---\nproject body $ARGUMENTS", project.appendingPathComponent(".claude/skills/shared/SKILL.md"))
        try write("# No front matter skill\nstuff", home.appendingPathComponent(".codex/skills/plain/SKILL.md"))
        try write("# /qa — Standalone QA\nDo QA for $ARGUMENTS", home.appendingPathComponent(".hosaka/integrations/claude/commands/qa.md"))
        return (SkillCatalog(homeDirectory: home, projectRoot: project), home, project)
    }

    func testDiscoveryAndOverridePrecedence() throws {
        let (catalog, _, project) = try makeCatalog()
        let shared = try XCTUnwrap(catalog.skill(named: "shared"))
        XCTAssertEqual(shared.source, .project)
        XCTAssertEqual(shared.description, "project version")
        XCTAssertEqual(catalog.skills.filter { $0.name == "shared" }.count, 1)
        let plain = try XCTUnwrap(catalog.skill(named: "plain"))
        XCTAssertEqual(plain.description, "No front matter skill")
        XCTAssertEqual(plain.source, .codexUser)
        let qa = try XCTUnwrap(catalog.skill(named: "qa"))
        XCTAssertEqual(qa.source, .hosakaCommand)
        XCTAssertEqual(qa.description, "/qa — Standalone QA")

        catalog.setProjectRoot(nil)
        XCTAssertEqual(catalog.skill(named: "shared")?.source, .claudeUser)
        catalog.setProjectRoot(project)
        XCTAssertEqual(catalog.skill(named: "shared")?.source, .project)
    }

    func testSlashParsing() throws {
        let (catalog, _, _) = try makeCatalog()
        let parsed = try XCTUnwrap(catalog.slashCommand(from: "/qa the login page"))
        XCTAssertEqual(parsed.0.name, "qa")
        XCTAssertEqual(parsed.1, "the login page")
        XCTAssertEqual(catalog.slashCommand(from: "/qa")?.1, "")
        XCTAssertNil(catalog.slashCommand(from: "/unknown thing"))
        XCTAssertNil(catalog.slashCommand(from: "qa thing"))
        XCTAssertNil(catalog.slashCommand(from: "/usr/bin/ls"))
    }

    func testPromptAndUseSkillTool() async throws {
        let (catalog, _, project) = try makeCatalog()
        let skill = try XCTUnwrap(catalog.skill(named: "shared"))
        let prompt = catalog.prompt(for: skill, arguments: "ARG1", projectRoot: project)
        XCTAssertTrue(prompt.contains("executing the skill \"shared\""))
        XCTAssertTrue(prompt.contains("project body ARG1"))
        XCTAssertTrue(prompt.contains("NEVER hand-write Hosaka evidence"))
        XCTAssertTrue(prompt.contains("approval"))

        let rt = ToolRuntime(projectRoot: project, approver: FakeApprover(.deny), skills: catalog,
                             approvals: ApprovalStore(fileURL: project.appendingPathComponent("ap.json")))
        let out = await rt.run(name: "wb_use_skill", argumentsJSON: #"{"name":"qa","arguments":"checkout"}"#)
        XCTAssertTrue(out.contains("Do QA for checkout"), out)
        let missing = await rt.run(name: "wb_use_skill", argumentsJSON: #"{"name":"nope"}"#)
        XCTAssertTrue(missing.contains("no skill named nope"))
    }
}
