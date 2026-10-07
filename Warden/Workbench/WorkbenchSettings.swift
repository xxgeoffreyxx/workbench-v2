import AppKit
import CoreData
import SwiftUI
import WorkbenchKit

// MARK: - Models

struct WorkbenchModelsSettings: View {
    @ObservedObject private var hub = WorkbenchHub.shared
    @State private var busyModel: String?
    @State private var output = ""
    @State private var warming: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Address", value: Workbench.routerBaseURL.absoluteString)
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(hub.routerOnline == true ? Color.green : hub.routerOnline == false ? .red : .secondary)
                            .frame(width: 8, height: 8)
                        Text(hub.routerOnline == true ? "Online" : hub.routerOnline == false ? "Offline" : "Checking…")
                    }
                }
                if let error = hub.lastRouterError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                Button("Check Now") { hub.refreshRouter() }
            } header: {
                Text("Model router")
            } footer: {
                Text("Set WORKBENCH_ROUTER_URL to use a different router. It appears as “Workbench Router” in API Services.")
            }

            Section("Resident models") {
                if hub.residentModels.isEmpty {
                    Text("No resident models reported.").foregroundStyle(.secondary)
                }
                ForEach(hub.residentModels) { model in
                    ResidentModelRow(model: model, busy: busyModel == model.canonical) { action in
                        run(model.canonical, action)
                    }
                }
                if !output.isEmpty {
                    Text(output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(hub.routerModels) { model in
                    HStack {
                        Circle().fill(model.ready ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        VStack(alignment: .leading) {
                            Text(model.title)
                            Text("\(model.modelID) · \(model.subtitle)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(model.role).font(.caption).foregroundStyle(.secondary)
                        Button(warming == model.id ? "Warming…" : "Warm Up") { warm(model) }
                            .disabled(warming != nil)
                    }
                }
            } header: {
                Text("Available models")
            } footer: {
                Text("Warm-up sends a tiny request so the first real reply isn't slowed by loading. Router-managed and Dorsett models are skipped.")
            }
        }
        .formStyle(.grouped)
        .onAppear { hub.refreshRouter() }
    }

    private func run(_ model: String, _ action: String) {
        busyModel = model
        Task {
            let result = await RouterClient.shared.control(model: model, action: action)
            busyModel = nil
            output = "\(action) \(model) → exit \(result.exitCode)\n" + String(result.output.suffix(1200))
            if result.exitCode != 0 { hub.reportModelError("\(action) \(model) failed (exit \(result.exitCode))") }
            hub.refreshRouter()
        }
    }

    private func warm(_ model: RouterModel) {
        warming = model.id
        Task {
            do {
                try await RouterClient.shared.warm(modelID: model.modelID, baseURL: URL(string: model.baseURL) ?? Workbench.routerBaseURL)
            } catch {
                hub.reportModelError("Warm-up of \(model.title) failed: \(error.localizedDescription)")
            }
            warming = nil
        }
    }
}

// MARK: - Notifications

struct WorkbenchNotificationSettings: View {
    @State private var enabled: [WorkbenchAlert: Bool] = Dictionary(
        uniqueKeysWithValues: WorkbenchAlert.allCases.map { ($0, $0.isEnabled) }
    )

    var body: some View {
        Form {
            Section {
                ForEach(WorkbenchAlert.allCases) { alert in
                    Toggle(isOn: Binding(
                        get: { enabled[alert] ?? true },
                        set: { value in
                            enabled[alert] = value
                            UserDefaults.standard.set(value, forKey: alert.defaultsKey)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.title)
                            Text(alert.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Notify me when")
            } footer: {
                Text("macOS must also allow notifications for Workbench in System Settings → Notifications.")
            }
            Section {
                Button("Open Notification Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
                Button("Send Test Notification") {
                    WorkbenchNotifier.shared.post(.routerError, title: "Workbench", body: "Notifications are working.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Import from the old Workbench

struct WorkbenchImportSettings: View {
    @Environment(\.managedObjectContext) private var context
    @State private var includeArchived = false
    @State private var result: String?
    @State private var available: Int?

    var body: some View {
        Form {
            Section {
                if let url = BenchImport.defaultThreadsURL() {
                    LabeledContent("Found", value: url.path)
                    if let available { LabeledContent("Threads", value: "\(available)") }
                    Toggle("Include archived threads", isOn: $includeArchived)
                    Button("Import Threads") { runImport(from: url) }
                } else {
                    Text("No threads from the old Workbench app were found.").foregroundStyle(.secondary)
                }
                if let result { Text(result).font(.callout) }
            } header: {
                Text("Old Workbench threads")
            } footer: {
                Text("Each thread becomes a chat on the Workbench Router. Threads with a folder go into a project linked to that folder. Importing twice skips threads already imported.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if let url = BenchImport.defaultThreadsURL() {
                available = (try? BenchImport.loadThreads(from: url))?.count
            }
        }
    }

    private func runImport(from url: URL) {
        do {
            let threads = try BenchImport.loadThreads(from: url)
            let count = try BenchThreadImporter.importThreads(threads, includeArchived: includeArchived, context: context)
            result = "Imported \(count) thread\(count == 1 ? "" : "s")."
        } catch {
            result = "Import failed: \(error.localizedDescription)"
        }
    }
}

@MainActor
enum BenchThreadImporter {
    static func importThreads(_ threads: [ImportedThread], includeArchived: Bool, context: NSManagedObjectContext) throws -> Int {
        let chatRequest = ChatEntity.fetchRequest() as! NSFetchRequest<ChatEntity>
        let existingIDs = Set(((try? context.fetch(chatRequest)) ?? []).map(\.id))

        let serviceRequest = APIServiceEntity.fetchRequest() as! NSFetchRequest<APIServiceEntity>
        let services = (try? context.fetch(serviceRequest)) ?? []
        let router = services.first { $0.name == WorkbenchProviders.routerName } ?? services.first

        let projectRequest = ProjectEntity.fetchRequest() as! NSFetchRequest<ProjectEntity>
        var projects = (try? context.fetch(projectRequest)) ?? []

        var imported = 0
        for thread in threads where !existingIDs.contains(thread.id) && (includeArchived || !thread.archived) {
            let chat = ChatEntity(context: context)
            chat.id = thread.id
            chat.name = thread.title
            chat.createdDate = thread.createdAt
            chat.updatedDate = thread.updatedAt
            chat.newChat = false
            chat.apiService = router
            chat.gptModel = modelID(from: thread.model) ?? router?.model ?? "ornith"
            chat.systemMessage = ""

            if let path = thread.workspacePath {
                chat.project = project(for: path, in: &projects, context: context)
            }

            var nextID: Int64 = 1
            for message in thread.messages where message.role == "user" || message.role == "assistant" {
                let entity = MessageEntity(context: context)
                entity.id = nextID
                nextID += 1
                entity.own = message.role == "user"
                entity.timestamp = message.createdAt
                entity.waitingForResponse = false
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    entity.body = "<think>\n\(reasoning)\n</think>\n\n\(message.content)"
                } else {
                    entity.body = message.content
                }
                entity.chat = chat
            }
            imported += 1
        }
        try context.save()
        return imported
    }

    /// Old threads stored the model as "<base URL>#<model id>".
    private static func modelID(from stored: String) -> String? {
        stored.split(separator: "#", maxSplits: 1).last.map(String.init)
    }

    private static func project(for path: String, in projects: inout [ProjectEntity], context: NSManagedObjectContext) -> ProjectEntity {
        let folders = ProjectFolders.shared
        if let match = projects.first(where: { folders.folder(for: $0)?.path == path }) { return match }
        let project = ProjectEntity(context: context)
        project.id = UUID()
        project.name = URL(fileURLWithPath: path).lastPathComponent
        project.createdAt = Date()
        project.updatedAt = Date()
        project.sortOrder = Int32(projects.count)
        projects.append(project)
        folders.setFolder(URL(fileURLWithPath: path, isDirectory: true), for: project)
        return project
    }
}
