import Foundation

/// Hosaka evidence is produced only by owner scripts. Model tools must never write it.
public enum EvidenceGuard {
    public static let protectedFilenames: Set<String> = [
        "QA-RESULT.json", "localhost-verification.json", "production-verification.json",
        "monitor-result.json", "code-review-result.json",
    ]

    public static let refusalMessage = "Refused: that target is Hosaka evidence. Evidence (anything under an evidence/ directory, QA-RESULT.json, localhost-verification.json, production-verification.json, monitor-result.json, code-review-result.json) is produced only by Hosaka owner scripts and must never be hand-written."

    /// True when a path (absolute or relative) is Hosaka evidence.
    public static func isProtected(path: String) -> Bool {
        let normalized = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        if normalized.contains("/evidence/") || normalized.hasSuffix("/evidence") { return true }
        let name = (normalized as NSString).lastPathComponent
        return protectedFilenames.contains(name)
    }

    /// Best-effort check for shell commands that write evidence via redirection, tee, cp, mv and friends.
    public static func commandWritesEvidence(_ command: String) -> Bool {
        let mentionsEvidence = command.contains("evidence/") || command.range(of: #"(^|[\s/"'=])evidence(\s|$|["'])"#, options: .regularExpression) != nil
            || protectedFilenames.contains(where: { command.contains($0) })
        guard mentionsEvidence else { return false }
        // Redirection straight into a protected target.
        for target in redirectTargets(command) where isProtected(path: target) { return true }
        let writers = [#"\btee\b"#, #"\bcp\b"#, #"\bmv\b"#, #"\binstall\b"#, #"\brsync\b"#, #"\bln\b"#, #"\btouch\b"#,
                       #"\bdd\b"#, #"\bsed\s+(-[a-zA-Z]*\s+)*-i"#, #"\bperl\s+-[a-zA-Z]*i"#, #">"#, #"\bditto\b"#,
                       #"\bwrite_text\b"#, #"writeFile"#, #"\bcurl\b.*\s-o\b"#]
        return writers.contains { command.range(of: $0, options: .regularExpression) != nil }
    }

    static func redirectTargets(_ command: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\d?>>?\s*([^\s;&|]+)"#) else { return [] }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        return regex.matches(in: command, range: range).compactMap { match in
            Range(match.range(at: 1), in: command).map { String(command[$0]) }
        }
    }

    /// File paths touched by a unified diff (`diff --git`, `---`, `+++` headers), without a/ b/ prefixes.
    public static func patchPaths(_ patch: String) -> [String] {
        var paths: [String] = []
        for rawLine in patch.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            var candidates: [String] = []
            if line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
                candidates.append(String(line.dropFirst(4)).components(separatedBy: "\t")[0])
            } else if line.hasPrefix("diff --git ") {
                candidates += line.dropFirst(11).split(separator: " ").map(String.init)
            } else if line.hasPrefix("rename to ") || line.hasPrefix("rename from ") || line.hasPrefix("copy to ") {
                candidates.append(line.components(separatedBy: " ").dropFirst(2).joined(separator: " "))
            }
            for var candidate in candidates {
                candidate = candidate.trimmingCharacters(in: .whitespaces)
                if candidate == "/dev/null" || candidate.isEmpty { continue }
                if candidate.hasPrefix("a/") || candidate.hasPrefix("b/") { candidate = String(candidate.dropFirst(2)) }
                if !paths.contains(candidate) { paths.append(candidate) }
            }
        }
        return paths
    }
}
