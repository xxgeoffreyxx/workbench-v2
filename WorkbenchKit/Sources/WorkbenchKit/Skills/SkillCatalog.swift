import Foundation

/// Discovers the user's native agent skills (Claude, Codex, project, Hosaka commands) so any model can run them.
public final class SkillCatalog: @unchecked Sendable {
    public let homeDirectory: URL
    public private(set) var projectRoot: URL?
    private let lock = NSLock()
    private var _skills: [Skill] = []

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, projectRoot: URL? = nil) {
        self.homeDirectory = homeDirectory
        self.projectRoot = projectRoot
        reload()
    }

    /// Effective skills (one per name, highest precedence wins), sorted by name.
    public var skills: [Skill] {
        lock.lock(); defer { lock.unlock() }
        return _skills
    }

    public func setProjectRoot(_ root: URL?) {
        projectRoot = root
        reload()
    }

    public func reload() {
        var found: [Skill] = []
        found += Self.scanSkillDirs(homeDirectory.appendingPathComponent(".hosaka/integrations/claude/commands"), source: .hosakaCommand)
        found += Self.scanSkillDirs(homeDirectory.appendingPathComponent(".codex/skills"), source: .codexUser)
        found += Self.scanSkillDirs(homeDirectory.appendingPathComponent(".claude/skills"), source: .claudeUser)
        if let projectRoot {
            found += Self.scanSkillDirs(projectRoot.appendingPathComponent(".claude/skills"), source: .project)
        }
        var byName: [String: Skill] = [:]
        for skill in found {
            if let existing = byName[skill.name], existing.source.precedence > skill.source.precedence { continue }
            byName[skill.name] = skill
        }
        let result = byName.values.sorted { $0.name < $1.name }
        lock.lock(); _skills = result; lock.unlock()
    }

    public func skill(named name: String) -> Skill? {
        let key = name.hasPrefix("/") ? String(name.dropFirst()) : name
        return skills.first { $0.name == key } ?? skills.first { $0.name.lowercased() == key.lowercased() }
    }

    /// Directories the model may read (read-only) besides the project: every skill directory plus ~/.hosaka.
    public var readableRoots: [URL] {
        var roots = [homeDirectory.appendingPathComponent(".hosaka")]
        for skill in skills where skill.source != .hosakaCommand { roots.append(skill.directory) }
        return roots
    }

    /// Parses "/qa foo bar" into (qa skill, "foo bar"). Returns nil when the command is not a known skill.
    public func slashCommand(from input: String) -> (Skill, String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return nil }
        let body = trimmed.dropFirst()
        let nameEnd = body.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) ?? body.endIndex
        let name = String(body[..<nameEnd])
        guard !name.isEmpty, !name.contains("/"), let skill = skill(named: name) else { return nil }
        let arguments = body[nameEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (skill, arguments)
    }

    /// Instruction text that lets any model execute a skill through the wb_ tools.
    public func prompt(for skill: Skill, arguments: String, projectRoot: URL?) -> String {
        let project = projectRoot?.path ?? self.projectRoot?.path
        var lines = [
            "You are executing the skill \"\(skill.name)\" (\(skill.source.rawValue), defined in \(skill.file.path)).",
            "Follow the skill instructions below exactly and in order. Do not skip steps, and do not claim a step succeeded unless a tool result shows it.",
            "You can only act through the wb_ tools provided in this conversation (wb_read_file, wb_list_files, wb_search_files, wb_write_file, wb_apply_patch, wb_run_command, wb_web_search, wb_web_fetch, wb_project_overview, wb_use_skill). If the skill mentions other tools (Bash, Read, Edit, Agent, MCP tools), use the closest wb_ equivalent; if none exists, say so plainly instead of pretending.",
            "Every shell command, file write and patch is shown to the user for approval first; a denial is final for that action, so adapt rather than retry the same thing.",
            "NEVER hand-write Hosaka evidence: nothing under any evidence/ directory, and never QA-RESULT.json, localhost-verification.json, production-verification.json, monitor-result.json or code-review-result.json. Evidence is produced only by Hosaka owner scripts, which you run via wb_run_command.",
            "Files referenced by the skill live in its directory \(skill.directory.path); read them with wb_read_file using absolute paths. The skill directory and ~/.hosaka are readable (read-only).",
        ]
        lines.append(project.map { "Project root: \($0). Relative paths in wb_ tools resolve against it." }
                     ?? "No project folder is attached, so file and command tools are unavailable; tell the user if the skill needs one.")
        lines.append("Arguments: \(arguments.isEmpty ? "(none)" : arguments)")
        lines.append("----- SKILL: \(skill.name) -----")
        lines.append(skill.body.replacingOccurrences(of: "$ARGUMENTS", with: arguments).trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("----- END SKILL -----")
        return lines.joined(separator: "\n\n")
    }

    /// Scans `<dir>/*/SKILL.md` and, for Hosaka command docs, `<dir>/*.md`.
    static func scanSkillDirs(_ directory: URL, source: SkillSource) -> [Skill] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var skills: [Skill] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if source == .hosakaCommand {
                guard entry.pathExtension == "md" else { continue }
                if let skill = load(file: entry, directory: directory, fallbackName: entry.deletingPathExtension().lastPathComponent,
                                    source: source, nameFromFile: true) { skills.append(skill) }
            } else {
                let file = entry.appendingPathComponent("SKILL.md")
                guard fm.fileExists(atPath: file.path) else { continue }
                if let skill = load(file: file, directory: entry, fallbackName: entry.lastPathComponent, source: source, nameFromFile: false) {
                    skills.append(skill)
                }
            }
        }
        return skills
    }

    static func load(file: URL, directory: URL, fallbackName: String, source: SkillSource, nameFromFile: Bool) -> Skill? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let (fields, body) = FrontMatter.parse(text)
        let name = nameFromFile ? fallbackName : ((fields["name"]?.isEmpty == false) ? fields["name"]! : fallbackName)
        let description = fields["description"].flatMap { $0.isEmpty ? nil : $0 } ?? FrontMatter.firstHeading(body) ?? name
        return Skill(name: name, description: description, body: body, directory: directory, file: file, source: source)
    }
}
