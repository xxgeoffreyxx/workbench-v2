import Foundation

/// Project-folder context for chats that belong to a project (ported from model-workbench).
public enum ProjectContext {
    /// Small header for tool-using models: branch, dirty files, ranked file list, files the user named.
    public static func overview(root: URL, query: String) async -> String {
        let path = root.path
        return await Task.detached(priority: .utility) { () -> String in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return "Project folder does not exist or is not a directory: \(path)"
            }
            var parts = ["PROJECT OVERVIEW: \(path)"]
            if let branch = Shell.runSync("/usr/bin/git", ["-C", path, "branch", "--show-current"]).successOutput {
                parts.append("Branch: \(branch.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            if let status = Shell.runSync("/usr/bin/git", ["-C", path, "status", "--short"]).successOutput,
               !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("Uncommitted changes:\n\(Shell.limit(status, characters: 1_200))")
            }
            let allFiles = candidateFiles(in: path)
            let appRoot = inferPrimaryAppRoot(from: allFiles)
            if let appRoot { parts.append("Primary app root: \(appRoot)") }
            let ranked = rankedFiles(allFiles, appRoot: appRoot)
            parts.append("\(allFiles.count) files. Most relevant 40:\n\(ranked.prefix(40).joined(separator: "\n"))")
            let referenced = referencedFiles(in: query, fileList: ranked)
            if !referenced.isEmpty {
                parts.append("Files the user named (read them with wb_read_file): \(referenced.joined(separator: ", "))")
            }
            return parts.joined(separator: "\n\n")
        }.value
    }

    /// Large packet with opened file contents, for models without tool support.
    public static func fullContext(root: URL, query: String) async -> String {
        let workspacePath = root.path
        return await Task.detached(priority: .utility) { () -> String in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: workspacePath, isDirectory: &isDirectory), isDirectory.boolValue else {
                return "Project context: path does not exist or is not a directory: \(workspacePath)"
            }
            var parts = [
                "PROJECT: \(workspacePath)",
                "This packet was collected by opening files on disk before the model call.",
                "Use OPENED FILE CONTENTS as inspected source files. Do not infer solely from the file list.",
            ]
            if let gitRoot = Shell.runSync("/usr/bin/git", ["-C", workspacePath, "rev-parse", "--show-toplevel"]).successOutput {
                parts.append("Git root: \(gitRoot.trimmingCharacters(in: .whitespacesAndNewlines))")
                if let branch = Shell.runSync("/usr/bin/git", ["-C", workspacePath, "branch", "--show-current"]).successOutput {
                    parts.append("Branch: \(branch.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                if let status = Shell.runSync("/usr/bin/git", ["-C", workspacePath, "status", "--short"]).successOutput {
                    parts.append("Git status:\n\(Shell.limit(status, characters: 5000))")
                }
                if let diffStat = Shell.runSync("/usr/bin/git", ["-C", workspacePath, "diff", "--stat"]).successOutput,
                   !diffStat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append("Current diff stat:\n\(Shell.limit(diffStat, characters: 3000))")
                }
            } else {
                parts.append("Not a git repository.")
            }
            let allFiles = candidateFiles(in: workspacePath)
            let appRoot = inferPrimaryAppRoot(from: allFiles)
            if let appRoot { parts.append("Primary app root inferred by local scanner: \(appRoot).") }
            let fileList = rankedFiles(allFiles, appRoot: appRoot)
            parts.append("Representative files, ranked by app relevance:\n\(fileList.prefix(180).joined(separator: "\n"))")
            let referenced = referencedFiles(in: query, fileList: fileList)
            if !referenced.isEmpty {
                parts.append("Files the user referenced (opened in full below): \(referenced.joined(separator: ", "))")
            }
            var remaining = 48_000
            var opened: [String] = [], sections: [String] = [], visible: [String] = []
            for relativePath in referenced + selectedContextFiles(from: fileList).filter({ !referenced.contains($0) }) {
                guard remaining > 800 else { break }
                guard let content = try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8) else { continue }
                let perFile = referenced.contains(relativePath) ? 20_000 : (relativePath.hasSuffix("index.html") ? 9_000 : 6_000)
                let clipped = Shell.limit(content, characters: min(remaining, perFile))
                remaining -= clipped.count
                opened.append(relativePath)
                sections.append("### \(relativePath)\n```\n\(clipped)\n```")
                if relativePath.hasSuffix(".html") {
                    let text = htmlVisibleText(from: content)
                    if !text.isEmpty { visible.append("### \(relativePath)\n\(Shell.limit(text, characters: 4_000))") }
                }
            }
            if sections.isEmpty {
                parts.append("OPENED FILE CONTENTS: none could be read from the ranked file list.")
            } else {
                parts.append("OPENED FILES:\n\(opened.joined(separator: "\n"))")
                if !visible.isEmpty { parts.append("VISIBLE TEXT EXTRACTS:\n\(visible.joined(separator: "\n\n"))") }
                parts.append("OPENED FILE CONTENTS:\n\(sections.joined(separator: "\n\n"))")
            }
            return parts.joined(separator: "\n\n")
        }.value
    }

    public static func candidateFiles(in workspacePath: String) -> [String] {
        let excluded = ["/.git/", "/node_modules/", "/.next/", "/dist/", "/build/", "/.build/", "/target/", "/vendor/",
                        "/Pods/", "/DerivedData/", "/coverage/", "/.cache/", "/Library/", "/.caddy/"]
        if let gitFiles = Shell.runSync("/usr/bin/git", ["-C", workspacePath, "ls-files", "--cached", "--others", "--exclude-standard"]).successOutput {
            return Array(Set(gitFiles.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                .filter { path in !excluded.contains { ("/" + path).contains($0) } })).sorted()
        }
        let pruned = [".git", "node_modules", ".next", "dist", "build", ".build", "target", "vendor", "Pods",
                      "DerivedData", "coverage", ".cache", ".caddy", "__pycache__"]
        var args = [workspacePath, "-maxdepth", "6", "("]
        for (index, name) in pruned.enumerated() {
            if index > 0 { args.append("-o") }
            args += ["-name", name]
        }
        args += [")", "-prune", "-o", "-type", "f", "-print"]
        let result = Shell.runSync("/usr/bin/find", args)
        guard result.exitCode == 0 else { return [] }
        let prefix = workspacePath.hasSuffix("/") ? workspacePath : workspacePath + "/"
        return result.output.split(separator: "\n").map(String.init)
            .filter { path in !excluded.contains { path.contains($0) } }
            .map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
            .sorted()
    }

    public static func inferPrimaryAppRoot(from fileList: [String]) -> String? {
        for candidate in ["www", "app", "src", "web", "frontend", "client"] where fileList.contains("\(candidate)/package.json") {
            return candidate
        }
        return fileList.contains("package.json") ? "." : nil
    }

    public static func rankedFiles(_ fileList: [String], appRoot: String?) -> [String] {
        func score(_ file: String) -> Int {
            var value = 0
            if let appRoot, appRoot != ".", file == "\(appRoot)/package.json" { value += 10_000 }
            if let appRoot, appRoot != ".", file.hasPrefix("\(appRoot)/") { value += 5_000 }
            if file.contains("/model-eval/") || file.hasPrefix("model-eval/") { value -= 4_000 }
            if file.hasSuffix("package.json") || file.hasSuffix("Package.swift") { value += 700 }
            if file.hasSuffix("astro.config.mjs") || file.hasSuffix("server.js") { value += 600 }
            if file.hasSuffix("index.html") || file.hasSuffix(".tsx") || file.hasSuffix(".ts") || file.hasSuffix(".swift") { value += 500 }
            if file == "README.md" || file == "CLAUDE.md" || file == "AGENTS.md" { value += 300 }
            if file.hasSuffix("package-lock.json") { value -= 800 }
            if file.hasSuffix(".DS_Store") { value -= 900 }
            if file.hasSuffix(".png") || file.hasSuffix(".jpg") || file.hasSuffix(".ico") { value -= 500 }
            return value
        }
        return fileList.sorted {
            let lhs = score($0), rhs = score($1)
            return lhs != rhs ? lhs > rhs : $0 < $1
        }.prefix(220).map { $0 }
    }

    public static func selectedContextFiles(from fileList: [String]) -> [String] {
        let exact = ["www/index.html", "www/package.json", "www/astro.config.mjs", "www/server.js", "www/tsconfig.json",
                     "README.md", "package.json", "Package.swift", "pyproject.toml", "Cargo.toml", "go.mod",
                     "requirements.txt", "tsconfig.json", "vite.config.ts"]
        let extensions = [".md", ".txt", ".swift", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".py", ".json", ".yaml",
                          ".yml", ".toml", ".html", ".astro", ".css", ".scss", ".go", ".rs", ".rb", ".java", ".kt", ".c",
                          ".h", ".cpp", ".cs", ".php", ".sh", ".bash", ".sql", ".graphql", ".vue", ".svelte", ".xml"]
        var selected = exact.filter { fileList.contains($0) }
        for file in fileList where selected.count < 40 {
            if selected.contains(file) { continue }
            if file.hasSuffix("package-lock.json") || file.hasSuffix("yarn.lock") || file.hasSuffix(".DS_Store") { continue }
            if extensions.contains(where: { file.hasSuffix($0) }) { selected.append(file) }
        }
        return selected
    }

    /// Files the user named by full path or a basename of at least 4 characters.
    public static func referencedFiles(in query: String, fileList: [String]) -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        var matches: [String] = []
        for path in fileList {
            let lower = path.lowercased()
            let base = (path as NSString).lastPathComponent.lowercased()
            if (q.contains(lower) || (base.count >= 4 && q.contains(base))) && !matches.contains(path) { matches.append(path) }
            if matches.count >= 8 { break }
        }
        return matches
    }

    /// Last ```patch or ```diff fenced block in a model reply.
    public static func extractPatchBlock(from content: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"```(?:patch|diff)\s*\n([\s\S]*?)\n```"#) else { return nil }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.matches(in: content, range: range).last,
              let patchRange = Range(match.range(at: 1), in: content) else { return nil }
        return String(content[patchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `git diff --check` plus status.
    public static func validate(root: URL) async -> String {
        let path = root.path
        return await Task.detached(priority: .utility) { () -> String in
            let check = Shell.runSync("/usr/bin/git", ["-C", path, "diff", "--check"])
            let head = check.exitCode == 0 ? "Validation passed: git diff --check" : "Validation failed: git diff --check\n\(check.output)"
            let status = Shell.runSync("/usr/bin/git", ["-C", path, "status", "--short"]).output
            return "\(head)\n\nGit status:\n\(Shell.limit(status, characters: 2000))"
        }.value
    }

    public static func htmlVisibleText(from html: String) -> String {
        var text = html
        for pattern in [#"(?is)<script\b[^>]*>.*?</script>"#, #"(?is)<style\b[^>]*>.*?</style>"#,
                        #"(?is)<svg\b[^>]*>.*?</svg>"#, #"(?is)<!--.*?-->"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "\n", options: .regularExpression)
        for (encoded, decoded) in ["&amp;": "&", "&mdash;": "-", "&ndash;": "-", "&nbsp;": " ", "&#x27;": "'",
                                   "&#39;": "'", "&quot;": "\"", "&lt;": "<", "&gt;": ">"] {
            text = text.replacingOccurrences(of: encoded, with: decoded)
        }
        return text.split(separator: "\n")
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
