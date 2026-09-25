import CoreData
import SwiftUI
import WorkbenchKit

/// One dropdown for the chat's model: router models first (named the way Bench named them), then DashScope,
/// then every other configured provider. Picking an item sets both the service and the model.
struct WorkbenchModelMenu: View {
    @ObservedObject var chat: ChatEntity
    @Environment(\.managedObjectContext) private var context
    @ObservedObject private var hub = WorkbenchHub.shared
    @ObservedObject private var cache = ModelCacheManager.shared

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \APIServiceEntity.addedDate, ascending: true)])
    private var services: FetchedResults<APIServiceEntity>

    private var routerService: APIServiceEntity? { services.first { $0.type == WorkbenchProviders.routerType } }

    /// Router aliases (ornith, hosaka-helga, deepseek-coder) all point at one model; show each real model once.
    private var routerEntries: [(id: String, title: String, ready: Bool)] {
        let fromHealth = hub.routerModels
            .filter { $0.baseURL.hasPrefix(Workbench.routerBaseURL.absoluteString) }
            .map { (id: $0.modelID, title: $0.title, ready: $0.ready) }
        if !fromHealth.isEmpty { return fromHealth }
        return cache.getModels(for: WorkbenchProviders.routerType).map { (id: $0.id, title: $0.id, ready: true) }
    }

    private var otherServices: [APIServiceEntity] {
        services.filter { $0.type != WorkbenchProviders.routerType }
    }

    private var label: String {
        if chat.apiService?.type == WorkbenchProviders.routerType,
           let entry = routerEntries.first(where: { $0.id == chat.gptModel }) {
            return entry.title
        }
        return chat.gptModel.isEmpty ? "Choose model" : chat.gptModel
    }

    var body: some View {
        Menu {
            if let routerService {
                Section("Local router") {
                    if routerEntries.isEmpty {
                        Text(hub.routerOnline == false ? "Router offline" : "No models reported")
                    }
                    ForEach(routerEntries, id: \.id) { entry in
                        item(title: entry.title + (entry.ready ? "" : " (paused)"), model: entry.id, service: routerService)
                    }
                }
            }
            ForEach(otherServices, id: \.objectID) { service in
                let models = modelIDs(for: service)
                if !models.isEmpty {
                    Section(service.name ?? service.type ?? "Provider") {
                        ForEach(models, id: \.self) { model in
                            item(title: model, model: model, service: service)
                        }
                    }
                }
            }
            Divider()
            Button("Manage Providers…") {
                SettingsWindowManager.shared.openSettingsWindow()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: chat.apiService?.type == WorkbenchProviders.routerType ? "cpu" : "cloud")
                Text(label).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("\(chat.apiService?.name ?? "No provider") · \(chat.gptModel)")
        .onAppear { hub.refreshRouter() }
    }

    private func modelIDs(for service: APIServiceEntity) -> [String] {
        guard let type = service.type else { return [] }
        let fetched = cache.getModelsSorted(for: type).map(\.id)
        let list = fetched.isEmpty ? (AppConstants.defaultApiConfigurations[type]?.models ?? []) : fetched
        // Keep the menu usable for providers with hundreds of models; the full list stays in Settings.
        return Array(list.prefix(25))
    }

    @ViewBuilder
    private func item(title: String, model: String, service: APIServiceEntity) -> some View {
        let selected = chat.apiService == service && chat.gptModel == model
        Button {
            chat.apiService = service
            chat.gptModel = model
            chat.updatedDate = Date()
            chat.objectWillChange.send()
            try? context.save()
            // The chat's sender holds a handler for one provider; rebuild it, as Warden's own picker does.
            NotificationCenter.default.post(name: .recreateMessageManager, object: nil, userInfo: ["chatId": chat.id])
        } label: {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}
