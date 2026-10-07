import Foundation

/// One OpenAI-style function tool. The JSON schema is stored serialized so the value stays `Sendable`.
public struct ToolSpec: Sendable, Equatable {
    public let name: String
    public let description: String
    /// The parameters JSON schema, serialized.
    public let parametersJSON: String

    public init(name: String, description: String, parametersJSONSchema: [String: Any]) {
        self.name = name
        self.description = description
        let data = (try? JSONSerialization.data(withJSONObject: parametersJSONSchema, options: [.sortedKeys])) ?? Data("{}".utf8)
        self.parametersJSON = String(decoding: data, as: UTF8.self)
    }

    public var parametersJSONSchema: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(parametersJSON.utf8))) as? [String: Any] ?? [:]
    }

    /// `{"type":"function","function":{name,description,parameters}}`
    public var openAIDefinition: [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description, "parameters": parametersJSONSchema] as [String: Any]]
    }

    /// Convenience for simple object schemas whose properties are all strings.
    static func object(_ properties: [(String, String)], required: [String]) -> [String: Any] {
        var props: [String: Any] = [:]
        for (key, description) in properties { props[key] = ["type": "string", "description": description] }
        return ["type": "object", "properties": props, "required": required]
    }
}
