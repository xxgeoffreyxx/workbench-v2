import Foundation

/// Talks to the local model router (:8110), the Dorsett LB and the resident-model control script.
public actor RouterClient {
    public static let shared = RouterClient()

    /// Script run by `control(model:action:)` as `<script> <model> <action>`.
    nonisolated(unsafe) public static var modelControlScript: String =
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("workbench-v2/Scripts/resident-model-control.sh").path

    public static let healthURL = URL(string: "http://127.0.0.1:8110/health")!
    /// A model warmed within this window is not warmed again.
    public static let warmTTL: TimeInterval = 90

    private var lastWarmedAt: [String: Date] = [:]
    private var warmTasks: [String: Task<Void, Error>] = [:]

    public init() {}

    public func health() async throws -> RouterHealthResponse {
        var request = URLRequest(url: Self.healthURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw NSError(domain: "Workbench", code: status, userInfo: [NSLocalizedDescriptionKey: "Router health HTTP \(status)"])
        }
        return try JSONDecoder().decode(RouterHealthResponse.self, from: data)
    }

    /// Router models (from /health) plus DashScope options, with Dorsett entries reflecting the LB probe.
    /// When the router is unreachable, falls back to `RouterModel.defaults` plus the DashScope options.
    public func models() async -> [RouterModel] {
        var result: [RouterModel]
        if let health = try? await health() {
            result = ModelCatalog.models(from: health)
        } else {
            result = []
        }
        if result.isEmpty {
            result = RouterModel.defaults + ModelCatalog.alibabaModelOptions()
        }
        return await Dorsett.refreshReadiness(in: result)
    }

    public func residentModels() async -> [ResidentModel] {
        guard let health = try? await health() else { return [] }
        return ModelCatalog.residentModels(from: health.models)
    }

    /// Pre-loads a model with a 1-token completion. Skipped (returns immediately) for DashScope,
    /// Dorsett, the :8110 router (kept resident by the m1max supervisor) and anything warmed within
    /// `warmTTL`. Joins an in-flight warm-up for the same model.
    public func warm(modelID: String, baseURL: URL = Workbench.routerBaseURL) async throws {
        if DashScope.isEndpoint(baseURL) { return }
        if modelID.hasPrefix(RouterModel.dorsettModelPrefix) { return }
        if baseURL.port == 8110 { return }
        if let warmedAt = lastWarmedAt[modelID], Date().timeIntervalSince(warmedAt) < Self.warmTTL { return }
        if let existing = warmTasks[modelID] {
            try await existing.value
            return
        }
        let task = Task { try await Self.warmModel(modelID: modelID, baseURL: baseURL) }
        warmTasks[modelID] = task
        defer { warmTasks[modelID] = nil }
        try await task.value
        lastWarmedAt[modelID] = Date()
    }

    /// Sends a throwaway `max_tokens: 1` completion; cold loads can take well over a minute.
    public static func warmModel(modelID: String, baseURL: URL, timeoutSeconds: TimeInterval = 180) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if DashScope.isEndpoint(baseURL) {
            guard let auth = DashScope.authorizationHeader() else {
                throw NSError(domain: "Workbench", code: 401, userInfo: [NSLocalizedDescriptionKey: "DashScope API key is missing. Add it to AIDash settings or set DASHSCOPE_API_KEY."])
            }
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": "warmup"]],
            "temperature": 0,
            "max_tokens": 1,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeoutSeconds
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "Workbench", code: status, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "HTTP \(status)"])
        }
    }

    /// Runs `modelControlScript <model> <action>` (action: start | stop | status).
    public func control(model: String, action: String) async -> (exitCode: Int32, output: String) {
        let script = Self.modelControlScript
        return await Task.detached(priority: .userInitiated) {
            let result = JobFeed.runCommand(script, [model, action])
            return (result.exitCode, result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }
}

/// Token telemetry appended to AIDash's local-mlx-usage.jsonl.
public enum Telemetry {
    public static var usageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIDash/local-mlx-usage.jsonl")
    }

    /// Records one completion's usage. Dorsett models are skipped (their server logs itself).
    /// `host`/`baseURL` default to the old app's fallbacks when the model isn't known.
    @discardableResult
    public static func record(
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        cachedTokens: Int? = nil,
        elapsed: TimeInterval,
        totalTokens: Int? = nil,
        host: String = "local-openai-compatible",
        baseURL: String = "http://127.0.0.1:8110/v1",
        source: String = "model-workbench"
    ) -> Bool {
        if model.hasPrefix(RouterModel.dorsettModelPrefix) { return false }
        let latencyMs = Int((elapsed * 1000).rounded())
        var row: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "source": source,
            "host": host,
            "base_url": baseURL,
            "model": model,
            "prompt_tokens": promptTokens,
            "completion_tokens": completionTokens,
            "total_tokens": totalTokens ?? (promptTokens + completionTokens),
            "latency_ms": latencyMs,
            "duration_ms": latencyMs,
        ]
        if let cachedTokens {
            row["cached_tokens"] = cachedTokens
        }
        do {
            let url = usageURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data("\n".utf8))
                try handle.close()
            } else {
                try (data + Data("\n".utf8)).write(to: url, options: .atomic)
            }
            return true
        } catch {
            return false
        }
    }
}
