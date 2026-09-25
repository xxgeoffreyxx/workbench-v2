import Foundation
import WorkbenchKit

/// Folder paths linked to Warden projects. Kept outside Core Data so the upstream data model stays untouched.
@MainActor
final class ProjectFolders: ObservableObject {
    static let shared = ProjectFolders()

    @Published private(set) var paths: [String: String] = [:]
    private let fileURL = Workbench.supportDirectory.appendingPathComponent("project-folders.json")

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            paths = decoded
        }
    }

    func folder(for project: ProjectEntity?) -> URL? {
        guard let id = project?.id?.uuidString, let path = paths[id] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func setFolder(_ url: URL?, for project: ProjectEntity) {
        guard let id = project.id else { return }
        paths[id.uuidString] = url?.path
        if let data = try? JSONEncoder().encode(paths) {
            try? data.write(to: fileURL, options: .atomic)
        }
        WorkbenchTools.shared.reset(projectID: id)
    }
}

/// Connects WorkbenchKit's tools and skills to Warden's chat loop: which tools a chat gets, how `wb_` calls run,
/// and the running transcript for a multi-round tool turn.
@MainActor
final class WorkbenchTools {
    static let shared = WorkbenchTools()

    /// Skills can take many steps (read, run tests, read output, fix...); plain chats stop sooner.
    static let maxRoundsWithSkill = 24
    static let maxRounds = 8

    private var runtimes: [String: ToolRuntime] = [:]
    private var catalogs: [String: SkillCatalog] = [:]
    /// Full request transcript for the turn in progress, so every tool round resends the system prompt and history.
    private var transcripts: [UUID: [[String: String]]] = [:]
    private var activeSkills: [UUID: String] = [:]

    var toolsEnabled: Bool {
        UserDefaults.standard.object(forKey: "workbench.tools.enabled") as? Bool ?? true
    }

    private func key(for chat: ChatEntity) -> String {
        ProjectFolders.shared.folder(for: chat.project)?.path ?? "-"
    }

    func catalog(for chat: ChatEntity?) -> SkillCatalog {
        let root = chat.flatMap { ProjectFolders.shared.folder(for: $0.project) }
        let key = root?.path ?? "-"
        if let existing = catalogs[key] { return existing }
        let catalog = SkillCatalog(projectRoot: root)
        catalogs[key] = catalog
        return catalog
    }

    func runtime(for chat: ChatEntity) -> ToolRuntime {
        let key = key(for: chat)
        if let existing = runtimes[key] { return existing }
        let runtime = ToolRuntime(
            projectRoot: ProjectFolders.shared.folder(for: chat.project),
            approver: MainWindowApprover(),
            skills: catalog(for: chat)
        )
        runtimes[key] = runtime
        return runtime
    }

    func reset(projectID: UUID) {
        runtimes.removeAll()
        catalogs.removeAll()
    }

    func reloadSkills() {
        for catalog in catalogs.values { catalog.reload() }
    }

    // MARK: - Tool definitions

    /// Workbench tools are offered when the chat has a project folder or a skill is running.
    /// Chats without either stay plain, so models without tool support aren't sent tools they can't use.
    func toolDefinitions(for chat: ChatEntity) -> [[String: Any]] {
        guard toolsEnabled, !isCodex(chat) else { return [] }
        let hasFolder = ProjectFolders.shared.folder(for: chat.project) != nil
        guard hasFolder || activeSkills[chat.id] != nil else { return [] }
        return runtime(for: chat).specs(includeSkills: true).map(\.openAIDefinition)
    }

    func handles(_ name: String) -> Bool { name.hasPrefix("wb_") }

    func run(name: String, argumentsJSON: String, chat: ChatEntity) async -> String {
        await runtime(for: chat).run(name: name, argumentsJSON: argumentsJSON)
    }

    func maxRounds(for chat: ChatEntity) -> Int {
        activeSkills[chat.id] != nil ? Self.maxRoundsWithSkill : Self.maxRounds
    }

    /// Codex and the agent CLIs bring their own tools.
    private func isCodex(_ chat: ChatEntity) -> Bool {
        chat.apiService?.type == "codex" || AgentCLI(rawValue: chat.apiService?.type ?? "") != nil
    }

    // MARK: - Turn setup

    /// Called with the freshly built request for a new user turn. Adds the project and skill notes to the system
    /// message, remembers whether a skill is active, and starts the turn transcript.
    func prepare(_ messages: [[String: String]], userMessage: String, chat: ChatEntity) -> [[String: String]] {
        var messages = messages
        var notes: [String] = []

        // Local models often claim to be whichever assistant wrote their training data. Tell them what they are.
        if chat.apiService?.type == WorkbenchProviders.routerType {
            let entry = WorkbenchHub.shared.routerModels.first { $0.modelID == chat.gptModel }
            let title = entry?.title ?? chat.gptModel
            // The router's /health lists the host; before that has loaded, fall back to the default model's entry.
            let resident = WorkbenchHub.shared.residentModels.first { $0.canonical == chat.gptModel }
                ?? WorkbenchHub.shared.residentModels.first
            let subtitleHost = (entry ?? RouterModel.defaults.first { $0.modelID == chat.gptModel })?
                .subtitle.components(separatedBy: " · ").dropFirst().first
            let host = (resident?.host ?? subtitleHost).map { "the Mac \"\($0)\"" } ?? "a Mac on Geoffrey's network"
            notes.append("""
            IDENTITY: You are \(title) (model id "\(chat.gptModel)"), an open-weight model running locally on \(host), \
            reached through Geoffrey's Thunderbolt MLX router at \(Workbench.routerBaseURL.absoluteString). You are not \
            Claude, ChatGPT or any cloud service, and nothing you process leaves Geoffrey's machines. If asked who or \
            where you are, say exactly that.
            """)
        }

        if let folder = ProjectFolders.shared.folder(for: chat.project), toolsEnabled {
            notes.append("""
            WORKBENCH PROJECT FOLDER: \(folder.path)
            You can inspect and change this project with the wb_ tools (list, read, search, write, apply patch, \
            run command, project overview, web search/fetch, use skill). Paths are relative to the project folder. \
            Every command, file write and patch is shown to the user for approval first; if one is denied, \
            say what you wanted to do instead of retrying. Never hand-write Hosaka evidence files.
            """)
        }

        if let (skill, arguments) = catalog(for: chat).slashCommand(from: userMessage) {
            activeSkills[chat.id] = skill.name
            notes.append(catalog(for: chat).prompt(
                for: skill,
                arguments: arguments,
                projectRoot: ProjectFolders.shared.folder(for: chat.project)
            ))
        } else {
            activeSkills.removeValue(forKey: chat.id)
        }

        if !notes.isEmpty {
            let extra = notes.joined(separator: "\n\n")
            if let index = messages.firstIndex(where: { $0["role"] == "system" }) {
                let existing = messages[index]["content"] ?? ""
                messages[index]["content"] = existing.isEmpty ? extra : existing + "\n\n" + extra
            } else {
                messages.insert(["role": "system", "content": extra], at: 0)
            }
        }

        transcripts[chat.id] = messages
        return messages
    }

    func appendToTranscript(_ message: [String: String], chat: ChatEntity) {
        transcripts[chat.id, default: []].append(message)
    }

    func transcript(for chat: ChatEntity) -> [[String: String]]? {
        transcripts[chat.id]
    }

    func finishTurn(chat: ChatEntity) {
        transcripts.removeValue(forKey: chat.id)
        activeSkills.removeValue(forKey: chat.id)
    }
}
