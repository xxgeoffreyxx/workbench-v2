import Foundation

public enum ApprovalKind: String, Sendable, Codable {
    case command, writeFile, patch
}

public struct ApprovalRequest: Sendable, Identifiable {
    public let id: UUID
    public let kind: ApprovalKind
    /// One-line human summary, e.g. "Run: npm test".
    public let summary: String
    /// The exact command, file content, or diff being approved.
    public let detail: String
    public let workingDirectory: String
    /// Standardized project root path; the key for always-allow rules.
    public let projectKey: String

    public init(id: UUID = UUID(), kind: ApprovalKind, summary: String, detail: String, workingDirectory: String, projectKey: String) {
        self.id = id; self.kind = kind; self.summary = summary; self.detail = detail
        self.workingDirectory = workingDirectory; self.projectKey = projectKey
    }
}

public enum ApprovalDecision: String, Sendable {
    case approve, alwaysAllow, deny
}

public protocol ToolApprover: Sendable {
    func approve(_ request: ApprovalRequest) async -> ApprovalDecision
}

/// Persisted always-allow command prefixes, keyed by project path.
/// Stored as JSON `{ "<project path>": ["git status", "npm test"] }`.
public final class ApprovalStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Workbench/approvals.json")
    }

    public init(fileURL: URL = ApprovalStore.defaultURL) {
        self.fileURL = fileURL
    }

    /// First token plus subcommand (second token when it is not a flag), e.g. `git status`, `npm run`.
    public static func commandPrefix(_ command: String) -> String {
        let tokens = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        guard let first = tokens.first else { return "" }
        if tokens.count > 1, !tokens[1].hasPrefix("-"),
           !["&&", "||", ";", "|", ">", ">>"].contains(tokens[1]),
           tokens[1].range(of: #"^[A-Za-z0-9:_.-]+$"#, options: .regularExpression) != nil {
            return "\(first) \(tokens[1])"
        }
        return first
    }

    public func allowedPrefixes(projectKey: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return load()[projectKey] ?? []
    }

    /// True when the command's prefix was always-allowed and the command has no chaining that could smuggle in another command.
    public static func hasChaining(_ command: String) -> Bool {
        [";", "&", "|", "`", "$(", "\n", ">", "<"].contains(where: { command.contains($0) })
    }

    public func isAllowed(command: String, projectKey: String) -> Bool {
        if Self.hasChaining(command) { return false }
        return allowedPrefixes(projectKey: projectKey).contains(Self.commandPrefix(command))
    }

    public func allow(command: String, projectKey: String) {
        // Chained/redirected commands are approved once but never remembered.
        guard !Self.hasChaining(command) else { return }
        let prefix = Self.commandPrefix(command)
        guard !prefix.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var all = load()
        var list = all[projectKey] ?? []
        if !list.contains(prefix) { list.append(prefix) }
        all[projectKey] = list
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() -> [String: [String]] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: [String]] ?? [:]
    }
}
