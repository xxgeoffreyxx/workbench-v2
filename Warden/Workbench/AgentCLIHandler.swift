import Foundation
import WorkbenchKit

/// Which coding-agent CLI a service runs. Both speak the same `--mode json` event stream.
enum AgentCLI: String, CaseIterable {
    case pi = "pi_agent"
    case omp = "omp_agent"

    var displayName: String { self == .pi ? "pi" : "oh-my-pi" }
    var executableName: String { self == .pi ? "pi" : "omp" }

    /// Looks in the usual install places; GUI apps don't inherit the shell's PATH.
    var executableURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["\(home)/.bun/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin"]
        return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(executableName) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// Per-send context the chat loop hands to the agent, since Warden's APIService only sees messages.
@MainActor
enum AgentCLIContext {
    struct Turn { let chatID: UUID; let folder: URL?; let allowWrites: Bool }
    static var current: Turn?

    static func allowWrites(for project: ProjectEntity?) -> Bool {
        guard let id = project?.id?.uuidString else { return false }
        return UserDefaults.standard.bool(forKey: "workbench.agent.allowWrites.\(id)")
    }

    static func setAllowWrites(_ value: Bool, for project: ProjectEntity) {
        guard let id = project.id?.uuidString else { return }
        UserDefaults.standard.set(value, forKey: "workbench.agent.allowWrites.\(id)")
    }
}

/// Runs pi or oh-my-pi as the chat's model: the latest user message goes to the agent CLI inside the chat's project
/// folder, and its text and tool activity stream back. Each chat keeps its own agent session, so follow-ups continue
/// where the agent left off. The agent runs its own tools; unless the project allows writes it only gets read tools.
final class AgentCLIHandler: APIService {
    /// Read-only tool sets; the two CLIs name their tools differently (omp has no `ls`, it uses `glob`).
    static func readOnlyTools(for cli: AgentCLI) -> String {
        cli == .pi ? "read,grep,find,ls" : "read,grep,glob"
    }

    let name: String
    let baseURL: URL
    let session: URLSession = .shared
    let model: String
    private let cli: AgentCLI

    init(cli: AgentCLI, model: String) {
        self.cli = cli
        self.name = cli.rawValue
        self.baseURL = URL(string: "stdio://\(cli.executableName)")!
        self.model = model
    }

    // MARK: - Running the agent

    static func sessionDirectory(cli: AgentCLI, chatID: UUID) -> URL {
        let dir = Workbench.supportDirectory.appendingPathComponent("agent-sessions/\(cli.executableName)/\(chatID.uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func arguments(cli: AgentCLI, model: String, prompt: String, sessionDir: URL, folder: URL?, allowWrites: Bool) -> [String] {
        var args = ["--mode", "json", "-p", "--session-dir", sessionDir.path]
        let hasSession = ((try? FileManager.default.contentsOfDirectory(atPath: sessionDir.path)) ?? []).contains { !$0.hasPrefix(".") }
        if hasSession { args.append("--continue") }
        if !model.isEmpty { args += ["--model", model] }
        if !allowWrites { args += ["--tools", readOnlyTools(for: cli)] }
        if cli == .omp {
            if let folder { args += ["--cwd", folder.path] } else { args.append("--allow-home") }
            // Workbench shows no approval UI for the agent's own tools; writes are gated by the tool list instead.
            args.append("--auto-approve")
        }
        args.append(prompt)
        return args
    }

    func sendMessageStream(
        _ requestMessages: [[String: String]],
        tools: [[String: Any]]?,
        settings: GenerationSettings
    ) async throws -> AsyncThrowingStream<(String?, [ToolCall]?), Error> {
        guard let executable = cli.executableURL else {
            throw APIError.noApiService("\(cli.displayName) isn't installed (looked for `\(cli.executableName)` in ~/.bun/bin, ~/.local/bin, /opt/homebrew/bin and /usr/local/bin).")
        }
        let prompt = requestMessages.last(where: { $0["role"] == "user" })?["content"] ?? ""
        let turn = await MainActor.run { AgentCLIContext.current }
        let chatID = turn?.chatID ?? UUID()
        let folder = turn?.folder
        let args = Self.arguments(
            cli: cli, model: model, prompt: prompt,
            sessionDir: Self.sessionDirectory(cli: cli, chatID: chatID),
            folder: folder, allowWrites: turn?.allowWrites ?? false
        )
        Diagnostics.log("agent start cli=\(cli.executableName) model=\(model) folder=\(folder?.path ?? "-") writes=\(turn?.allowWrites ?? false)")

        return AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            process.currentDirectoryURL = folder ?? FileManager.default.temporaryDirectory
            // The agent waits on stdin if it's left open.
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            var environment = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            environment["PATH"] = "\(home)/.bun/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment

            let parser = AgentEventParser()
            var buffer = Data()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    for output in parser.consume(line: Data(line)) {
                        continuation.yield((output, nil))
                    }
                }
            }
            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                Diagnostics.log("agent end cli=\(self.cli.executableName) status=\(proc.terminationStatus) error=\(parser.error ?? "-")")
                if let error = parser.error {
                    continuation.finish(throwing: APIError.serverError(error))
                } else if proc.terminationStatus != 0 && !parser.producedText {
                    let detail = errText.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.finish(throwing: APIError.serverError(
                        "\(self.cli.displayName) exited with status \(proc.terminationStatus)" + (detail.isEmpty ? "" : ": \(detail.suffix(600))")))
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: APIError.requestFailed(error))
            }
        }
    }

    func sendMessage(
        _ requestMessages: [[String: String]],
        tools: [[String: Any]]?,
        settings: GenerationSettings,
        completion: @escaping (Result<(String?, [ToolCall]?), APIError>) -> Void
    ) {
        Task {
            do {
                var text = ""
                for try await (chunk, _) in try await sendMessageStream(requestMessages, tools: tools, settings: settings) {
                    text += chunk ?? ""
                }
                completion(.success((text, nil)))
            } catch let error as APIError {
                completion(.failure(error))
            } catch {
                completion(.failure(.requestFailed(error)))
            }
        }
    }

    /// Model IDs as `provider/model`, from the CLI's own model list (Workbench's router models come first).
    func fetchModels() async throws -> [AIModel] {
        guard let executable = cli.executableURL else { return [] }
        let args = cli == .pi ? ["--list-models"] : ["models", "--json"]
        let result = await Shell.run(executable.path, arguments: args, cwd: nil, timeoutSeconds: 30)
        let ids = cli == .pi ? Self.parsePiModelTable(result.output) : Self.parseOmpModelJSON(result.output)
        return ids.sorted { ($0.hasPrefix("workbench/") ? 0 : 1, $0) < ($1.hasPrefix("workbench/") ? 0 : 1, $1) }
            .map { AIModel(id: $0) }
    }

    static func parsePiModelTable(_ text: String) -> [String] {
        text.split(separator: "\n").dropFirst().compactMap { line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2 else { return nil }
            return "\(cols[0])/\(cols[1])"
        }
    }

    static func parseOmpModelJSON(_ text: String) -> [String] {
        guard let start = text.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let data = String(text[start...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let items: [[String: Any]]
        if let array = json as? [[String: Any]] { items = array }
        else if let dict = json as? [String: Any], let array = dict["models"] as? [[String: Any]] { items = array }
        else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            if let provider = item["provider"] as? String { return id.hasPrefix(provider + "/") ? id : "\(provider)/\(id)" }
            return id
        }
    }

    // MARK: - HTTP-only parts of the protocol, unused for a CLI agent

    func prepareRequest(
        requestMessages: [[String: String]], tools: [[String: Any]]?, model: String,
        settings: GenerationSettings, attachmentPolicy: AttachmentPolicy, stream: Bool
    ) async throws -> URLRequest {
        throw APIError.unknown("\(cli.displayName) runs as a local process, not over HTTP")
    }

    func parseJSONResponse(data: Data) -> (String?, String?, [ToolCall]?)? { nil }
    func parseDeltaJSONResponse(data: Data?) -> (Bool, Error?, String?, String?, [ToolCall]?) { (false, nil, nil, nil, nil) }
}

/// Turns pi/omp JSON events into chat text: assistant text deltas as they stream, a one-line note per tool call,
/// and the error message if the model call failed.
final class AgentEventParser {
    private(set) var error: String?
    private(set) var producedText = false

    func consume(line: Data) -> [String] {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = event["type"] as? String else { return [] }
        switch type {
        case "message_update":
            guard let update = event["assistantMessageEvent"] as? [String: Any],
                  update["type"] as? String == "text_delta",
                  let delta = update["delta"] as? String, !delta.isEmpty else { return [] }
            producedText = true
            return [delta]
        case "tool_execution_start":
            let tool = event["toolName"] as? String ?? "tool"
            let args = (event["args"] as? [String: Any]).flatMap { Self.summary(of: $0) } ?? ""
            return ["\n\n`▸ \(tool)\(args.isEmpty ? "" : ": " + args)`\n\n"]
        case "tool_execution_end":
            if event["isError"] as? Bool == true { return ["`  ↳ failed`\n\n"] }
            return []
        case "message_end":
            if let message = event["message"] as? [String: Any], message["role"] as? String == "assistant",
               let text = message["errorMessage"] as? String, !text.isEmpty {
                error = text
            }
            return []
        case "agent_end":
            // A later retry that succeeds clears an earlier error.
            if producedText { error = nil }
            return []
        default:
            return []
        }
    }

    static func summary(of args: [String: Any]) -> String {
        for key in ["command", "path", "file_path", "pattern", "query"] {
            if let value = args[key] as? String { return String(value.prefix(120)) }
        }
        return ""
    }
}
