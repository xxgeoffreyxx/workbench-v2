import Foundation

// Ported from model-workbench/Sources/main.swift (router, model discovery, Dorsett, DashScope).

public struct RouterHealthResponse: Decodable, Sendable {
    public struct NetworkContext: Decodable, Sendable {
        public let on_home_local: Bool?
        public let has_thunderbolt_link_local: Bool?
        public let cloud_fallback_enabled: Bool?
        public let local_cloud_fallback_approved: Bool?
    }

    public struct ModelStatus: Decodable, Sendable {
        public struct CloudFallback: Decodable, Sendable {
            public let provider: String?
            public let configured: Bool?
            public let model: String?
        }

        public let host: String?
        public let network: String?
        public let network_label: String?
        public let model: String?
        public let aliases: [String]?
        public let ready: Bool
        public let cloud_fallback: CloudFallback?
    }

    public let ok: Bool
    public let active_requests: Int?
    public let network_context: NetworkContext?
    public let models: [String: ModelStatus]?
}

public struct RouterModelsResponse: Decodable, Sendable {
    public struct Model: Decodable, Sendable {
        public let id: String
        public let ready: Bool?
        public let owned_by: String?
        public let canonical: String?
        public let backend_model: String?
    }

    public let data: [Model]
}

public struct ResidentModel: Identifiable, Hashable, Sendable {
    public let canonical: String
    public let title: String
    public let host: String
    public let ready: Bool
    public var id: String { canonical }

    public init(canonical: String, title: String, host: String, ready: Bool) {
        self.canonical = canonical
        self.title = title
        self.host = host
        self.ready = ready
    }
}

public struct ModelEndpoint: Hashable, Sendable {
    public let name: String
    public let baseURL: URL

    public init(name: String, baseURL: URL) {
        self.name = name
        self.baseURL = baseURL
    }
}

/// A selectable model (the old app's `ModelOption`).
public struct RouterModel: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let modelID: String
    public let title: String
    public let subtitle: String
    public let role: String
    public let baseURL: String
    public let ready: Bool

    public init(id: String, modelID: String, title: String, subtitle: String, role: String, baseURL: String, ready: Bool) {
        self.id = id
        self.modelID = modelID
        self.title = title
        self.subtitle = subtitle
        self.role = role
        self.baseURL = baseURL
        self.ready = ready
    }

    /// Shown until the router answers; live entries come from /health.
    public static let defaults = [
        RouterModel(id: "http://127.0.0.1:8110/v1#ornith", modelID: "ornith", title: "Ornith (Helga)", subtitle: "Router · m1max · paused", role: "coding + QA", baseURL: "http://127.0.0.1:8110/v1", ready: false),
    ]

    /// Dorsett: three Qwen3-1.7B fine-tunes on m1max reached through the hpx Caddy LB. Not offered
    /// in the picker; never warmed or load-probed with completions.
    public static let dorsettJudgeURL = "http://192.168.1.163:8117/v1"
    public static let dorsettExtractURL = "http://192.168.1.163:8120/v1"
    public static let dorsettModelPrefix = "/Users/m1max/dorsett-"

    public static func dorsett(ready: Bool) -> [RouterModel] {
        let state = ready ? "m1max via hpx LB" : "m1max via hpx LB · offline"
        return [
            RouterModel(id: "\(dorsettJudgeURL)#/Users/m1max/dorsett-baseline-mlx-8bit", modelID: "/Users/m1max/dorsett-baseline-mlx-8bit", title: "Dorsett Judge", subtitle: "\(state) · :8117", role: "job match judge", baseURL: dorsettJudgeURL, ready: ready),
            RouterModel(id: "\(dorsettJudgeURL)#/Users/m1max/dorsett-13-mlx-8bit", modelID: "/Users/m1max/dorsett-13-mlx-8bit", title: "Dorsett 1.10 Writer", subtitle: "\(state) · :8117", role: "voice writer", baseURL: dorsettJudgeURL, ready: ready),
            RouterModel(id: "\(dorsettExtractURL)#/Users/m1max/dorsett-extract-mlx-8bit", modelID: "/Users/m1max/dorsett-extract-mlx-8bit", title: "Dorsett Extract", subtitle: "\(state) · :8120", role: "JD extraction", baseURL: dorsettExtractURL, ready: ready),
        ]
    }

    public var isDorsett: Bool { modelID.hasPrefix(Self.dorsettModelPrefix) }
}

/// Pure model-catalogue logic (no I/O except the DashScope key lookup).
public enum ModelCatalog {
    public static let routerBaseURL = "http://127.0.0.1:8110/v1"

    public static let candidateEndpoints = [
        ModelEndpoint(name: "MBP Router", baseURL: URL(string: "http://127.0.0.1:8110/v1")!),
    ]

    public static func models(from routerHealth: RouterHealthResponse) -> [RouterModel] {
        guard let routerModels = routerHealth.models, !routerModels.isEmpty else { return [] }

        let onHomeLocal = routerHealth.network_context?.on_home_local ?? false
        let thunderboltLinked = routerHealth.network_context?.has_thunderbolt_link_local ?? false
        let cloudEnabled = routerHealth.network_context?.cloud_fallback_enabled ?? false
        let localCloudApproved = routerHealth.network_context?.local_cloud_fallback_approved ?? false
        let showCloudFallbacks = cloudEnabled && !thunderboltLinked && (!onHomeLocal || localCloudApproved)

        var optionsByID: [String: RouterModel] = [:]
        for (routerID, status) in routerModels {
            guard let canonical = canonicalWorkbenchModelID(for: routerID, backend: status.model ?? routerID) else {
                continue
            }
            let subtitleNetwork = status.network_label ?? status.network ?? "Router"
            optionsByID[canonical] = RouterModel(
                id: "http://127.0.0.1:8110/v1#\(canonical)",
                modelID: canonical,
                title: displayTitle(for: canonical),
                subtitle: "Router · \(status.host ?? "local") · \(subtitleNetwork)\(status.ready ? "" : " · offline")",
                role: status.model ?? canonical,
                baseURL: "http://127.0.0.1:8110/v1",
                ready: status.ready
            )

            if !status.ready,
               showCloudFallbacks,
               status.cloud_fallback?.configured == true,
               let cloudModel = status.cloud_fallback?.model {
                optionsByID["\(canonical)-cloud"] = RouterModel(
                    id: "http://127.0.0.1:8110/v1#\(canonical)-cloud",
                    modelID: canonical,
                    title: "Alibaba \(displayTitle(for: canonical))",
                    subtitle: "\(status.cloud_fallback?.provider ?? "Alibaba Cloud") · fallback online",
                    role: cloudModel,
                    baseURL: "http://127.0.0.1:8110/v1",
                    ready: true
                )
            }
        }

        for model in alibabaModelOptions() {
            optionsByID[model.id] = model
        }

        return optionsByID.values.sorted {
            if $0.ready != $1.ready { return $0.ready && !$1.ready }
            let lhsRank = modelSortRank($0.modelID)
            let rhsRank = modelSortRank($1.modelID)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    public static func residentModels(from routerModels: [String: RouterHealthResponse.ModelStatus]?) -> [ResidentModel] {
        var byCanonical: [String: ResidentModel] = [:]
        for (routerID, status) in routerModels ?? [:] {
            guard let canonical = canonicalWorkbenchModelID(for: routerID, backend: status.model ?? routerID) else { continue }
            let ready = (byCanonical[canonical]?.ready ?? false) || status.ready
            byCanonical[canonical] = ResidentModel(canonical: canonical, title: displayTitle(for: canonical), host: status.host ?? "local", ready: ready)
        }
        return byCanonical.values.sorted {
            let l = modelSortRank($0.canonical), r = modelSortRank($1.canonical)
            return l != r ? l < r : $0.title < $1.title
        }
    }

    public static func readinessByCanonicalModel(from routerModels: [String: RouterHealthResponse.ModelStatus]?) -> [String: Bool] {
        guard let routerModels else { return [:] }
        return routerModels.reduce(into: [:]) { readiness, item in
            let (routerID, status) = item
            guard let canonical = canonicalWorkbenchModelID(for: routerID, backend: status.model ?? routerID) else { return }
            readiness[canonical] = (readiness[canonical] ?? false) || status.ready
        }
    }

    public static func discoverModels(endpoints: [ModelEndpoint] = candidateEndpoints) async -> [RouterModel] {
        await withTaskGroup(of: [RouterModel].self) { group in
            for endpoint in endpoints {
                group.addTask { await fetchModels(from: endpoint) }
            }

            var seenCanonical = Set<String>()
            var options: [RouterModel] = []
            var flattened: [RouterModel] = []
            for await result in group {
                flattened.append(contentsOf: result)
            }
            for model in flattened.sorted(by: preferModelOption) {
                let canonical = canonicalWorkbenchModelID(for: model.modelID) ?? model.modelID
                if !seenCanonical.contains(canonical) {
                    seenCanonical.insert(canonical)
                    options.append(model)
                }
            }

            return options.sorted {
                if $0.ready != $1.ready { return $0.ready && !$1.ready }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    public static func fetchModels(from endpoint: ModelEndpoint) async -> [RouterModel] {
        do {
            var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("models"))
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 8
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return [] }
            let decoded = try JSONDecoder().decode(RouterModelsResponse.self, from: data)
            return models(from: decoded, endpoint: endpoint)
        } catch {
            return []
        }
    }

    public static func models(from decoded: RouterModelsResponse, endpoint: ModelEndpoint) -> [RouterModel] {
        decoded.data.compactMap { model in
            guard let canonical = model.canonical.flatMap({ canonicalWorkbenchModelID(for: $0, backend: model.backend_model) })
                ?? canonicalWorkbenchModelID(for: model.id, backend: model.backend_model) else {
                return nil
            }
            let ready = model.ready ?? true
            let owner = model.owned_by ?? endpoint.name
            let title = displayTitle(for: canonical)
            return RouterModel(
                id: "\(endpoint.baseURL.absoluteString)#\(canonical)",
                modelID: model.id,
                title: title,
                subtitle: "\(endpoint.name) · \(owner)\(ready ? "" : " · paused")",
                role: model.backend_model ?? model.id,
                baseURL: endpoint.baseURL.absoluteString,
                ready: ready
            )
        }
    }

    public static func preferModelOption(_ lhs: RouterModel, _ rhs: RouterModel) -> Bool {
        if lhs.ready != rhs.ready { return lhs.ready && !rhs.ready }
        let lhsRouter = lhs.baseURL == "http://127.0.0.1:8110/v1"
        let rhsRouter = rhs.baseURL == "http://127.0.0.1:8110/v1"
        if lhsRouter != rhsRouter { return lhsRouter && !rhsRouter }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    public static func canonicalWorkbenchModelID(for modelID: String, backend: String? = nil) -> String? {
        let normalized = String(modelID.split(separator: "#").last ?? Substring(modelID)).lowercased()
        let combined = "\(normalized) \(backend ?? "")".lowercased()
        if normalized == "qwen-cloud" || normalized == "qwen-plus" {
            return "qwen-plus"
        }
        if normalized == "qwen-flash" {
            return "qwen-flash"
        }
        if normalized == "ornith" || normalized == "deepseek-coder" || normalized == "hosaka-helga" || combined.contains("ornith") {
            return "ornith"
        }
        if retiredModelMatchers.contains(where: { combined.contains($0) }) { return nil }
        if normalized.hasPrefix("/") || normalized.contains("dorsett") { return nil }
        // Any other router model (a new Mac or model) is shown under its own router ID.
        if backend != nil { return normalized }
        return nil
    }

    /// Retired 2026-09-23; the router may still list their backends.
    public static let retiredModelMatchers = [
        "qwen30", "qwen3-30b", "hosaka-peer", "qwen3-4b", "deepseek-coder-v2-lite",
    ]

    public static func modelSortRank(_ modelID: String) -> Int {
        switch modelID {
        case "ornith", "deepseek-coder", "hosaka-helga": return 0
        case "qwen-plus", "qwen-cloud": return 4
        case "qwen-flash": return 5
        default: return 99
        }
    }

    public static func displayTitle(for modelID: String) -> String {
        switch modelID {
        case "ornith", "deepseek-coder", "hosaka-helga":
            return "Ornith (Helga)"
        case "qwen-plus", "qwen-cloud":
            return "Alibaba Qwen Plus"
        case "qwen-flash":
            return "Alibaba Qwen Flash"
        default:
            return modelID
        }
    }

    public static func alibabaModelOptions() -> [RouterModel] {
        let ready = DashScope.apiKey() != nil
        let baseURL = DashScope.baseURL
        return [
            RouterModel(
                id: "\(baseURL)#qwen-plus",
                modelID: "qwen-plus",
                title: "Alibaba Qwen Plus",
                subtitle: "DashScope US · \(ready ? "API key configured" : "missing API key")",
                role: "cloud reasoning + coding",
                baseURL: baseURL,
                ready: ready
            ),
            RouterModel(
                id: "\(baseURL)#qwen-flash",
                modelID: "qwen-flash",
                title: "Alibaba Qwen Flash",
                subtitle: "DashScope US · \(ready ? "API key configured" : "missing API key")",
                role: "cloud fast classification",
                baseURL: baseURL,
                ready: ready
            ),
        ]
    }
}

public enum DashScope {
    public static let baseURL = "https://dashscope-us.aliyuncs.com/compatible-mode/v1"

    public static func isEndpoint(_ url: URL) -> Bool {
        url.host?.localizedCaseInsensitiveContains("dashscope") == true
    }

    public static func authorizationHeader() -> String? {
        apiKey().map { "Bearer \($0)" }
    }

    public static func apiKey() -> String? {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIDash/settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["dashscopeApiKey"] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        let env = ProcessInfo.processInfo.environment
        for key in ["DASHSCOPE_API_KEY", "ALIBABA_DASHSCOPE_API_KEY"] {
            if let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

public enum Dorsett {
    /// Sent as the system prompt for free-form chat with Dorsett heads (agreed 2026-09-17).
    public static let chatSystemPrompt = "You are Dorsett, a 1.7B small language model created by Geoffrey McCaleb for JobSift. If asked what you are, say exactly that, in one sentence, and nothing more. Do not describe yourself as friendly, helpful, or an assistant. Do not mention Qwen or Alibaba. Answer every question plainly and directly."

    public static let renderKeys = ["summary", "content", "description"]

    /// Reads the first balanced JSON object and returns its first non-empty render key, with the raw text.
    public static func summary(from content: String) -> (summary: String, raw: String)? {
        var depth = 0
        var end: String.Index?
        var inString = false
        var escaped = false
        for index in content.indices {
            let character = content[index]
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            if inString { continue }
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { end = content.index(after: index); break }
            }
        }
        guard let end,
              let data = String(content[content.startIndex..<end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in renderKeys {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (value, content)
            }
        }
        return nil
    }

    /// Pulls the first renderable string value out of an unterminated (token-capped) object.
    public static func fragmentValue(from content: String) -> String? {
        for key in renderKeys {
            guard let keyRange = content.range(of: "\"\(key)\":") else { continue }
            let rest = content[keyRange.upperBound...].drop(while: { $0 == " " })
            guard rest.first == "\"" else { continue }
            var value = ""
            var escaped = false
            for character in rest.dropFirst() {
                if escaped {
                    value.append(character == "n" ? "\n" : character)
                    escaped = false
                    continue
                }
                if character == "\\" { escaped = true; continue }
                if character == "\"" { break }
                value.append(character)
            }
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
        }
        return nil
    }

    /// Probes the Dorsett LB with GET /v1/models (no inference) and returns reachability.
    public static func checkReadiness() async -> Bool {
        var request = URLRequest(url: URL(string: "\(RouterModel.dorsettJudgeURL)/models")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 6
        if let (_, response) = try? await URLSession.shared.data(for: request) {
            return (response as? HTTPURLResponse)?.statusCode == 200
        }
        return false
    }

    /// Replaces the Dorsett entries in `models` with fresh ones reflecting `reachable`.
    public static func refreshReadiness(in models: [RouterModel]) async -> [RouterModel] {
        let reachable = await checkReadiness()
        var updated = models.filter { !$0.isDorsett }
        updated.append(contentsOf: RouterModel.dorsett(ready: reachable))
        return updated
    }
}

public enum ReasoningExtractor {
    /// Splits `<think>…</think>` blocks out of a response. Reasoning is nil when there are none.
    public static func split(_ raw: String) -> (reasoning: String?, content: String) {
        guard raw.range(of: "<think>", options: .caseInsensitive) != nil,
              let regex = try? NSRegularExpression(pattern: "<think>(.*?)</think>", options: [.dotMatchesLineSeparators, .caseInsensitive])
        else {
            return (nil, raw)
        }
        let ns = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (nil, raw) }
        let reasoning = matches
            .map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let content = regex
            .stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (reasoning.isEmpty ? nil : reasoning, content)
    }
}
