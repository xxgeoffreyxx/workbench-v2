import Foundation

public enum SkillSource: String, Sendable, Codable, Comparable {
    case hosakaCommand, codexUser, claudeUser, project

    /// Higher wins when two skills share a name.
    public var precedence: Int {
        switch self {
        case .hosakaCommand: return 0
        case .codexUser: return 1
        case .claudeUser: return 2
        case .project: return 3
        }
    }

    public static func < (lhs: SkillSource, rhs: SkillSource) -> Bool { lhs.precedence < rhs.precedence }
}

public struct Skill: Identifiable, Sendable, Equatable {
    /// `<source>:<name>`
    public var id: String { "\(source.rawValue):\(name)" }
    public let name: String
    public let description: String
    /// Markdown body with front matter removed.
    public let body: String
    public let directory: URL
    public let file: URL
    public let source: SkillSource

    public init(name: String, description: String, body: String, directory: URL, file: URL, source: SkillSource) {
        self.name = name; self.description = description; self.body = body
        self.directory = directory; self.file = file; self.source = source
    }
}

/// Minimal YAML front matter parser: flat `key: value` pairs, quoted strings, and `|` / `>` block scalars.
public enum FrontMatter {
    public static func parse(_ text: String) -> (fields: [String: String], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" || $0 == "..." })
        else { return ([:], normalized) }
        let header = Array(lines[1..<end])
        lines.removeSubrange(0...end)
        var fields: [String: String] = [:]
        var index = 0
        while index < header.count {
            let line = header[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("|") || value.hasPrefix(">") {
                let folded = value.hasPrefix(">")
                var block: [String] = []
                while index < header.count, header[index].hasPrefix(" ") || header[index].hasPrefix("\t") || header[index].isEmpty {
                    block.append(header[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                value = block.joined(separator: folded ? " " : "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } else if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "''", with: "'")
            }
            if !key.isEmpty { fields[key] = value }
        }
        return (fields, lines.joined(separator: "\n"))
    }

    /// First markdown heading text, without leading `#`s.
    public static func firstHeading(_ body: String) -> String? {
        for line in body.components(separatedBy: "\n") where line.hasPrefix("#") {
            let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }
}
