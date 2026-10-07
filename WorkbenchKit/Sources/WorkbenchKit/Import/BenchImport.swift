import Foundation

public struct ImportedMessage: Codable, Hashable, Sendable {
    public var role: String
    public var content: String
    public var reasoning: String?
    public var createdAt: Date

    public init(role: String, content: String, reasoning: String? = nil, createdAt: Date) {
        self.role = role; self.content = content; self.reasoning = reasoning; self.createdAt = createdAt
    }
}

public struct ImportedThread: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var model: String
    public var workspacePath: String?
    public var messages: [ImportedMessage]
    public var createdAt: Date
    public var updatedAt: Date
    public var archived: Bool

    public init(id: UUID, title: String, model: String, workspacePath: String?, messages: [ImportedMessage],
                createdAt: Date, updatedAt: Date, archived: Bool) {
        self.id = id; self.title = title; self.model = model; self.workspacePath = workspacePath
        self.messages = messages; self.createdAt = createdAt; self.updatedAt = updatedAt; self.archived = archived
    }

    // The legacy file stores `archived` as optional; extra keys (activityLog, status) are ignored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Imported thread"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        workspacePath = try c.decodeIfPresent(String.self, forKey: .workspacePath)
        messages = try c.decodeIfPresent([ImportedMessage].self, forKey: .messages) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }
}

/// Reads the threads.json written by the original (pre-v2) Workbench app.
public enum BenchImport {
    /// `~/Library/Application Support/Workbench/threads.json`, falling back to the
    /// pre-rename `ModelWorkbench` folder. Nil when neither exists.
    public static func defaultThreadsURL() -> URL? {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        for folder in ["Workbench", "ModelWorkbench"] {
            let url = support.appendingPathComponent(folder).appendingPathComponent("threads.json")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    public static func loadThreads(from url: URL) throws -> [ImportedThread] {
        try decodeThreads(Data(contentsOf: url))
    }

    public static func decodeThreads(_ data: Data) throws -> [ImportedThread] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ImportedThread].self, from: data)
    }
}
