import AppKit
import CoreData
import SwiftUI
import WorkbenchKit

/// Right-hand panel for the selected chat, modelled on BoltAI's inspector:
/// per-chat settings, the project folder and skills, and model / router status.
struct WorkbenchInspector: View {
    @ObservedObject var chat: ChatEntity

    enum Tab: String, CaseIterable, Identifiable {
        case settings, project, info
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .settings: return "slider.horizontal.3"
            case .project: return "folder"
            case .info: return "info.circle"
            }
        }
        var help: String {
            switch self {
            case .settings: return "Chat settings"
            case .project: return "Project folder and skills"
            case .info: return "Model and router status"
            }
        }
    }

    @AppStorage("workbench.inspectorTab") private var tab: Tab = .settings

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Image(systemName: tab.symbol).help(tab.help).accessibilityLabel(tab.help).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            ScrollView {
                Group {
                    switch tab {
                    case .settings: ChatSettingsTab(chat: chat)
                    case .project: ProjectTab(chat: chat)
                    case .info: InfoTab(chat: chat)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
        }
        .frame(minWidth: 260, idealWidth: 300)
    }
}

private struct Card<Content: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Settings

private struct ChatSettingsTab: View {
    @ObservedObject var chat: ChatEntity
    @Environment(\.managedObjectContext) private var context
    @State private var editingPrompt = false
    @State private var draftPrompt = ""

    private var effectivePrompt: String { chat.persona?.systemMessage ?? chat.systemMessage }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Card(title: "System prompt", footnote: chat.persona != nil
                ? "Set by the “\(chat.persona?.name ?? "")” assistant. Edit it in Settings → Assistants."
                : "Sent at the start of every request in this chat.") {
                if editingPrompt {
                    TextEditor(text: $draftPrompt)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 120)
                    HStack {
                        Spacer()
                        Button("Cancel") { editingPrompt = false }
                        Button("Save") {
                            chat.systemMessage = draftPrompt
                            try? context.save()
                            editingPrompt = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Text(effectivePrompt.isEmpty ? "None" : effectivePrompt)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(effectivePrompt.isEmpty ? .secondary : .primary)
                        .lineLimit(6)
                    if chat.persona == nil {
                        Button("Edit") {
                            draftPrompt = chat.systemMessage
                            editingPrompt = true
                        }
                    }
                }
            }

            Card(title: "Parameters", footnote: "Temperature 0 uses the assistant's or the app's default.") {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(chat.temperature == 0 ? "Default" : String(format: "%.1f", chat.temperature))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { chat.temperature }, set: { chat.temperature = $0; try? context.save() }), in: 0...2, step: 0.1)

                if let service = chat.apiService {
                    Stepper(value: Binding(
                        get: { Int(service.contextSize) },
                        set: { service.contextSize = Int16($0); try? context.save() }
                    ), in: 2...100, step: 2) {
                        HStack {
                            Text("History sent")
                            Spacer()
                            Text("\(service.contextSize) messages").foregroundStyle(.secondary)
                        }
                    }
                    Text("History applies to every chat using \(service.name ?? "this service").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Project

private struct ProjectTab: View {
    @ObservedObject var chat: ChatEntity
    @ObservedObject private var folders = ProjectFolders.shared
    @AppStorage("workbench.tools.enabled") private var toolsEnabled = true
    @State private var skills: [Skill] = []

    private var folder: URL? { folders.folder(for: chat.project) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Card(title: "Project folder", footnote: chat.project == nil
                ? "Move this chat into a project to link a folder."
                : "Tools can read this folder; commands, writes and patches ask you first.") {
                if let project = chat.project {
                    Label(project.name ?? "Project", systemImage: "folder.fill")
                    if let folder {
                        Text(folder.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        HStack {
                            Button("Change…") { pickFolder(for: project) }
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                            Button("Unlink") { folders.setFolder(nil, for: project) }
                        }
                    } else {
                        Button("Link Folder…") { pickFolder(for: project) }
                    }
                } else {
                    Text("No project").foregroundStyle(.secondary)
                }
                Toggle("Workbench tools", isOn: $toolsEnabled)
                    .help("Offer file, command, web and skill tools to models in project chats")
            }

            Card(title: "Skills", footnote: "Type /name in the message box to run one with the current model.") {
                if skills.isEmpty {
                    Text("No skills found").foregroundStyle(.secondary)
                }
                ForEach(skills.prefix(60)) { skill in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("/\(skill.name)").font(.callout.monospaced())
                        if !skill.description.isEmpty {
                            Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                Button("Reload Skills") {
                    WorkbenchTools.shared.reloadSkills()
                    loadSkills()
                }
            }
        }
        .onAppear(perform: loadSkills)
        .onChange(of: folders.paths) { _, _ in loadSkills() }
        .onChange(of: chat.project) { _, _ in loadSkills() }
    }

    private func loadSkills() {
        skills = WorkbenchTools.shared.catalog(for: chat).skills.sorted { $0.name < $1.name }
    }

    private func pickFolder(for project: ProjectEntity) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Link Folder"
        panel.message = "Choose the folder for “\(project.name ?? "this project")”"
        if panel.runModal() == .OK, let url = panel.url {
            folders.setFolder(url, for: project)
        }
    }
}

// MARK: - Info

private struct InfoTab: View {
    @ObservedObject var chat: ChatEntity
    @ObservedObject private var hub = WorkbenchHub.shared
    @State private var controlOutput: String?
    @State private var busyModel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Card(title: "This chat") {
                row("Service", chat.apiService?.name ?? "—")
                row("Model", chat.gptModel)
                row("Messages", "\(chat.messages.count)")
                if let project = chat.project { row("Project", project.name ?? "—") }
            }

            Card(title: "Router", footnote: Workbench.routerBaseURL.absoluteString) {
                HStack {
                    Circle()
                        .fill(hub.routerOnline == true ? Color.green : hub.routerOnline == false ? .red : .secondary)
                        .frame(width: 8, height: 8)
                    Text(hub.routerOnline == true ? "Online" : hub.routerOnline == false ? "Offline" : "Checking…")
                    Spacer()
                    Button { hub.refreshRouter() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                }
                if let error = hub.lastRouterError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
                ForEach(hub.residentModels) { model in
                    ResidentModelRow(model: model, busy: busyModel == model.canonical) { action in
                        runControl(model: model.canonical, action: action)
                    }
                }
                if let controlOutput {
                    Text(controlOutput)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func runControl(model: String, action: String) {
        busyModel = model
        Task {
            let result = await RouterClient.shared.control(model: model, action: action)
            busyModel = nil
            controlOutput = String(result.output.suffix(1200))
            if result.exitCode != 0 {
                hub.reportModelError("\(action) \(model) failed (exit \(result.exitCode))")
            }
            hub.refreshRouter()
        }
    }
}

struct ResidentModelRow: View {
    let model: ResidentModel
    let busy: Bool
    let action: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(model.ready ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.callout)
                Text(model.host).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    Button("Start") { action("start") }
                    Button("Stop") { action("stop") }
                    Button("Status") { action("status") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}
