import Foundation

/// Executes the built-in `wb_` tools for any model that speaks OpenAI-style tool calls.
/// Every result is a string for the model; failures are reported as text, never thrown.
public final class ToolRuntime: @unchecked Sendable {
    public let projectRoot: URL?
    public let approver: ToolApprover
    public let skills: SkillCatalog
    public let approvals: ApprovalStore
    public var commandTimeoutSeconds: Double = 120
    public var outputCharacterCap: Int = 20_000

    public static let noProjectMessage = "No project folder is attached to this chat, so file and command tools are unavailable. Ask the user to attach a project folder."

    public init(projectRoot: URL?, approver: ToolApprover, skills: SkillCatalog, approvals: ApprovalStore = ApprovalStore()) {
        self.projectRoot = projectRoot.map { URL(fileURLWithPath: PathConfinement.canonical($0.path)) }
        self.approver = approver
        self.skills = skills
        self.approvals = approvals
    }

    private var projectKey: String { projectRoot?.path ?? "" }

    // MARK: Specs

    public static let fileToolSpecs: [ToolSpec] = [
        ToolSpec(name: "wb_list_files",
                 description: "List project files (git-tracked and untracked, ignoring build output). Optional directory prefix and substring filter. Up to 200 relative paths.",
                 parametersJSONSchema: ToolSpec.object([("directory", "Relative directory prefix, e.g. 'src/' (optional)"),
                                                        ("contains", "Only paths containing this text (optional)")], required: [])),
        ToolSpec(name: "wb_read_file",
                 description: "Read a text file with line numbers, up to 400 lines per call. Paths are relative to the project root; absolute paths are allowed inside the project, skill directories, and ~/.hosaka (read-only).",
                 parametersJSONSchema: ToolSpec.object([("path", "File path"), ("start_line", "First line, 1-based (optional)")], required: ["path"])),
        ToolSpec(name: "wb_search_files",
                 description: "Search project files for a regex (ripgrep). Returns path:line:text, up to 150 lines.",
                 parametersJSONSchema: ToolSpec.object([("pattern", "Regular expression"), ("glob", "File glob such as '*.ts' (optional)")], required: ["pattern"])),
        ToolSpec(name: "wb_write_file",
                 description: "Create or overwrite a project file with the full given content. The user must approve.",
                 parametersJSONSchema: ToolSpec.object([("path", "Path relative to the project root"), ("content", "Complete new file content")], required: ["path", "content"])),
        ToolSpec(name: "wb_apply_patch",
                 description: "Apply a unified diff (git apply format, paths relative to the project root). The user must approve.",
                 parametersJSONSchema: ToolSpec.object([("patch", "Unified diff text")], required: ["patch"])),
        ToolSpec(name: "wb_run_command",
                 description: "Run a shell command (zsh -lc) in the project. The user approves each command unless they always-allowed it. Returns exit code and output (tail kept when long).",
                 parametersJSONSchema: ToolSpec.object([("command", "Shell command"), ("cwd", "Working directory relative to the project root (optional)"),
                                                        ("timeout_seconds", "Timeout, default 120, max 600 (optional)")], required: ["command"])),
        ToolSpec(name: "wb_project_overview",
                 description: "Project summary: branch, uncommitted changes, most relevant files.",
                 parametersJSONSchema: ToolSpec.object([("query", "What you are looking for, to surface named files (optional)")], required: [])),
    ]

    public static let webToolSpecs: [ToolSpec] = [
        ToolSpec(name: "wb_web_search",
                 description: "Search the public web (local SearXNG). Returns titles, URLs and snippets.",
                 parametersJSONSchema: ToolSpec.object([("query", "Search query")], required: ["query"])),
        ToolSpec(name: "wb_web_fetch",
                 description: "Read one web page as text, capped at 12,000 characters.",
                 parametersJSONSchema: ToolSpec.object([("url", "http(s) URL")], required: ["url"])),
    ]

    public static let skillToolSpec = ToolSpec(
        name: "wb_use_skill",
        description: "Load one of the user's agent skills (e.g. qa, review, refine) and get its full instructions to follow.",
        parametersJSONSchema: ToolSpec.object([("name", "Skill name"), ("arguments", "Arguments for the skill (optional)")], required: ["name"]))

    public func specs(includeSkills: Bool) -> [ToolSpec] {
        var all = Self.fileToolSpecs + Self.webToolSpecs
        if includeSkills {
            let names = skills.skills.prefix(80).map { "\($0.name): \(Shell.limit($0.description, characters: 90))" }
            let listing = names.isEmpty ? "" : " Available: " + names.joined(separator: "; ")
            all.append(ToolSpec(name: Self.skillToolSpec.name, description: Self.skillToolSpec.description + listing,
                                parametersJSONSchema: Self.skillToolSpec.parametersJSONSchema))
        }
        return all
    }

    public func handles(_ name: String) -> Bool {
        (Self.fileToolSpecs + Self.webToolSpecs + [Self.skillToolSpec]).contains { $0.name == name }
    }

    // MARK: Dispatch

    public func run(name: String, argumentsJSON: String) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        func string(_ key: String) -> String? {
            if let value = args[key] as? String, !value.isEmpty { return value }
            if let value = args[key] as? NSNumber { return value.stringValue }
            return nil
        }
        switch name {
        case "wb_web_search": return await WebTools.search(string("query") ?? "")
        case "wb_web_fetch": return await WebTools.fetch(string("url") ?? "")
        case "wb_use_skill":
            guard let skillName = string("name") else { return "wb_use_skill: name is required" }
            guard let skill = skills.skill(named: skillName) else {
                return "wb_use_skill: no skill named \(skillName). Available: \(skills.skills.map(\.name).joined(separator: ", "))"
            }
            return skills.prompt(for: skill, arguments: string("arguments") ?? "", projectRoot: projectRoot)
        case "wb_read_file":
            guard let path = string("path") else { return "wb_read_file: path is required" }
            return readFile(path, startLine: Int(string("start_line") ?? "1") ?? 1)
        case "wb_list_files", "wb_search_files", "wb_write_file", "wb_apply_patch", "wb_run_command", "wb_project_overview":
            guard let root = projectRoot else { return Self.noProjectMessage }
            switch name {
            case "wb_list_files": return listFiles(root: root, directory: string("directory"), contains: string("contains"))
            case "wb_search_files":
                guard let pattern = string("pattern") else { return "wb_search_files: pattern is required" }
                return await searchFiles(root: root, pattern: pattern, glob: string("glob"))
            case "wb_write_file":
                guard let path = string("path") else { return "wb_write_file: path is required" }
                return await writeFile(root: root, path: path, content: args["content"] as? String ?? "")
            case "wb_apply_patch":
                guard let patch = string("patch") else { return "wb_apply_patch: patch is required" }
                return await applyPatch(root: root, patch: patch)
            case "wb_run_command":
                guard let command = string("command") else { return "wb_run_command: command is required" }
                let timeout = min(600, max(1, Double(string("timeout_seconds") ?? "") ?? commandTimeoutSeconds))
                return await runCommand(root: root, command: command, cwd: string("cwd"), timeout: timeout)
            default: return await ProjectContext.overview(root: root, query: string("query") ?? "")
            }
        default:
            return "Unknown tool: \(name)"
        }
    }

    // MARK: Paths

    /// Resolves a path for reading: project root first, then read-only roots (skill dirs, ~/.hosaka) for absolute paths.
    public func resolveReadable(_ path: String) -> String? {
        if let root = projectRoot, let resolved = PathConfinement.confined(path, root: root) { return resolved }
        let expanded = path.hasPrefix("~/") ? skills.homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path : path
        guard expanded.hasPrefix("/") else { return nil }
        for root in skills.readableRoots {
            if let resolved = PathConfinement.confined(expanded, root: root) { return resolved }
        }
        return nil
    }

    /// Resolves a writable path inside the project, or returns an error message.
    func resolveWritable(_ path: String, root: URL, tool: String) -> Result<String, ToolError> {
        guard let resolved = PathConfinement.confined(path, root: root) else {
            return .failure(ToolError("\(tool): \(path) is outside the project folder"))
        }
        if EvidenceGuard.isProtected(path: path) || EvidenceGuard.isProtected(path: resolved) {
            return .failure(ToolError("\(tool): \(EvidenceGuard.refusalMessage)"))
        }
        return .success(resolved)
    }

    struct ToolError: Error { let message: String; init(_ m: String) { message = m } }

    // MARK: Tools

    func readFile(_ path: String, startLine: Int) -> String {
        if projectRoot == nil && !path.hasPrefix("/") && !path.hasPrefix("~/") { return Self.noProjectMessage }
        guard let resolved = resolveReadable(path) else {
            return "wb_read_file: \(path) is outside the project folder and the readable skill/Hosaka directories"
        }
        guard let content = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            return "wb_read_file: cannot read \(path) (missing, a directory, or not UTF-8 text)"
        }
        let lines = content.components(separatedBy: "\n")
        let start = max(1, startLine)
        guard start <= lines.count else { return "wb_read_file: \(path) has only \(lines.count) lines" }
        let end = min(lines.count, start + 399)
        var out = (start...end).map { "\($0)\t\(lines[$0 - 1])" }.joined(separator: "\n")
        if out.count > 24_000 { out = String(out.prefix(24_000)) + "\n... (character cap reached)" }
        if end < lines.count { out += "\n... \(lines.count - end) more lines; call wb_read_file with start_line \(end + 1)." }
        return "\(path) (lines \(start)-\(end) of \(lines.count))\n\(out)"
    }

    func listFiles(root: URL, directory: String?, contains: String?) -> String {
        var files = ProjectContext.candidateFiles(in: root.path)
        if let directory {
            let prefix = directory.hasPrefix("./") ? String(directory.dropFirst(2)) : directory
            if prefix != "." && !prefix.isEmpty { files = files.filter { $0.hasPrefix(prefix) } }
        }
        if let contains = contains?.lowercased() { files = files.filter { $0.lowercased().contains(contains) } }
        if files.isEmpty { return "No matching files." }
        let shown = files.prefix(200).joined(separator: "\n")
        return files.count > 200 ? "\(shown)\n... \(files.count - 200) more; narrow with directory or contains." : shown
    }

    func searchFiles(root: URL, pattern: String, glob: String?) async -> String {
        let rgPath = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        let result: ShellResult
        if let rgPath {
            var arguments = ["-n", "--no-heading", "--max-columns", "240", "--max-count", "20",
                             "-g", "!node_modules", "-g", "!.git", "-g", "!dist", "-g", "!build"]
            if let glob { arguments += ["-g", glob] }
            arguments += ["-e", pattern, "."]
            result = await Shell.run(rgPath, arguments: arguments, cwd: root.path, timeoutSeconds: 60)
        } else {
            var arguments = ["-rnIE", "--exclude-dir=node_modules", "--exclude-dir=.git"]
            if let glob { arguments.append("--include=\(glob)") }
            arguments += ["-e", pattern, "."]
            result = await Shell.run("/usr/bin/grep", arguments: arguments, cwd: root.path, timeoutSeconds: 60)
        }
        let lines = result.output.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.isEmpty { return result.exitCode > 1 ? "wb_search_files failed: \(result.output)" : "No matches for \(pattern)." }
        let shown = lines.prefix(150).joined(separator: "\n")
        return lines.count > 150 ? "\(shown)\n... \(lines.count - 150) more matches; refine the pattern or glob." : shown
    }

    func writeFile(root: URL, path: String, content: String) async -> String {
        let resolved: String
        switch resolveWritable(path, root: root, tool: "wb_write_file") {
        case .failure(let error): return error.message
        case .success(let value): resolved = value
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory)
        if isDirectory.boolValue { return "wb_write_file: \(path) is a directory" }
        let request = ApprovalRequest(kind: .writeFile,
                                      summary: "\(exists ? "Overwrite" : "Create") \(path) (\(content.count) characters)",
                                      detail: content, workingDirectory: root.path, projectKey: projectKey)
        guard await approver.approve(request) != .deny else { return "wb_write_file: the user denied writing \(path)." }
        do {
            try FileManager.default.createDirectory(atPath: (resolved as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try content.write(toFile: resolved, atomically: true, encoding: .utf8)
            return "Wrote \(path) (\(content.split(separator: "\n", omittingEmptySubsequences: false).count) lines)."
        } catch {
            return "wb_write_file failed: \(error.localizedDescription)"
        }
    }

    func applyPatch(root: URL, patch rawPatch: String) async -> String {
        let patch = (ProjectContext.extractPatchBlock(from: rawPatch) ?? rawPatch).trimmingCharacters(in: .newlines) + "\n"
        let paths = EvidenceGuard.patchPaths(patch)
        if paths.isEmpty { return "wb_apply_patch: no file headers found; send a unified diff with ---/+++ lines." }
        for path in paths {
            if case .failure(let error) = resolveWritable(path, root: root, tool: "wb_apply_patch") { return error.message }
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-\(UUID().uuidString).patch")
        do { try patch.write(to: tempURL, atomically: true, encoding: .utf8) } catch { return "wb_apply_patch failed: \(error.localizedDescription)" }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let check = await Shell.run("/usr/bin/git", arguments: ["apply", "--check", "--recount", tempURL.path], cwd: root.path, timeoutSeconds: 30)
        guard check.exitCode == 0 else { return "wb_apply_patch: patch does not apply cleanly:\n\(Shell.limit(check.output, characters: 4000))" }
        let request = ApprovalRequest(kind: .patch, summary: "Apply patch to \(paths.joined(separator: ", "))",
                                      detail: patch, workingDirectory: root.path, projectKey: projectKey)
        guard await approver.approve(request) != .deny else { return "wb_apply_patch: the user denied the patch." }
        let apply = await Shell.run("/usr/bin/git", arguments: ["apply", "--recount", tempURL.path], cwd: root.path, timeoutSeconds: 30)
        guard apply.exitCode == 0 else { return "wb_apply_patch failed:\n\(Shell.limit(apply.output, characters: 4000))" }
        return "Patch applied to: \(paths.joined(separator: ", "))"
    }

    func runCommand(root: URL, command: String, cwd: String?, timeout: Double) async -> String {
        if EvidenceGuard.commandWritesEvidence(command) {
            return "wb_run_command: \(EvidenceGuard.refusalMessage) Run the Hosaka owner script that produces it instead."
        }
        var directory = root.path
        if let cwd {
            guard let resolved = PathConfinement.confined(cwd, root: root) else { return "wb_run_command: cwd \(cwd) is outside the project folder" }
            directory = resolved
        }
        if !approvals.isAllowed(command: command, projectKey: projectKey) {
            let request = ApprovalRequest(kind: .command, summary: "Run: \(Shell.limit(command, characters: 120))",
                                          detail: command, workingDirectory: directory, projectKey: projectKey)
            switch await approver.approve(request) {
            case .deny: return "wb_run_command: the user denied running this command."
            case .alwaysAllow: approvals.allow(command: command, projectKey: projectKey)
            case .approve: break
            }
        }
        let result = await Shell.run("/bin/zsh", arguments: ["-lc", command], cwd: directory, timeoutSeconds: timeout)
        let output = result.output.isEmpty ? "(no output)" : Shell.limitTail(result.output, characters: outputCharacterCap)
        let header = result.timedOut ? "Timed out after \(Int(timeout))s (exit code \(result.exitCode))" : "Exit code: \(result.exitCode)"
        return "\(header)\n\(output)"
    }
}
