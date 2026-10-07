import Foundation

public enum WebTools {
    public static var searxngBase: String {
        ProcessInfo.processInfo.environment["HOSAKA_SEARXNG_URL"] ?? "http://192.168.1.139:8888"
    }

    public static func search(_ query: String) async -> String {
        guard !query.isEmpty, var components = URLComponents(string: "\(searxngBase)/search") else { return "wb_web_search: missing query" }
        components.queryItems = [.init(name: "q", value: query), .init(name: "format", value: "json")]
        guard let url = components.url else { return "wb_web_search: bad query" }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let results = (json?["results"] as? [[String: Any]] ?? []).prefix(8)
            if results.isEmpty { return "No results for: \(query)" }
            return results.enumerated().map { index, result in
                let title = (result["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let link = result["url"] as? String ?? ""
                let snippet = Shell.limit((result["content"] as? String ?? "")
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression), characters: 300)
                return "\(index + 1). \(title)\n   \(link)\n   \(snippet)"
            }.joined(separator: "\n")
        } catch {
            return "wb_web_search failed (SearXNG at \(searxngBase)): \(error.localizedDescription)"
        }
    }

    /// Uses ~/.local/bin/web-fetch when present (rendered markdown), else a plain GET reduced to visible text.
    public static func fetch(_ urlString: String) async -> String {
        guard urlString.hasPrefix("http://") || urlString.hasPrefix("https://"), let url = URL(string: urlString) else {
            return "wb_web_fetch: need an http(s) url"
        }
        let helper = NSString(string: "~/.local/bin/web-fetch").expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: helper) {
            let result = await Shell.run(helper, arguments: [urlString, "12000"], timeoutSeconds: 60)
            return result.output.isEmpty ? "(no output)" : result.output
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let text = ProjectContext.htmlVisibleText(from: String(decoding: data, as: UTF8.self))
            return Shell.limit(text, characters: 12_000)
        } catch {
            return "wb_web_fetch failed: \(error.localizedDescription)"
        }
    }
}
