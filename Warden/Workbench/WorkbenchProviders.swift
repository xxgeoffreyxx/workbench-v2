import CoreData
import Foundation
import WorkbenchKit

/// Seeds the providers Workbench needs: the local model router (Helga and the resident models) as the default
/// for new chats, and Alibaba's DashScope when a key is configured. Each has its own provider type because
/// Warden's model picker and model cache hold one service per type.
enum WorkbenchProviders {
    static let routerType = "workbench_router"
    static let dashScopeType = "dashscope"
    static let routerName = "Workbench Router"
    static let dashScopeName = "DashScope"
    private static let seededKey = "workbench.providersSeeded.v2"

    @MainActor
    static func ensureDefaults(context: NSManagedObjectContext) {
        disableRouterStreaming(context: context)
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }

        let request = APIServiceEntity.fetchRequest() as! NSFetchRequest<APIServiceEntity>
        let existing = (try? context.fetch(request)) ?? []

        // v1 seeded both as "openai_custom"; move them onto their own types.
        let router = existing.first { $0.type == routerType || $0.name == routerName }
            ?? make(name: routerName, url: Workbench.routerBaseURL.appendingPathComponent("chat/completions"),
                    model: RouterModel.defaults.first?.modelID ?? "ornith", context: context)
        router.type = routerType
        router.useStreamResponse = false

        if let dashScope = existing.first(where: { $0.type == dashScopeType || $0.name == dashScopeName }) {
            dashScope.type = dashScopeType
        } else if let key = DashScope.apiKey() {
            let service = make(name: dashScopeName, url: URL(string: DashScope.baseURL + "/chat/completions")!,
                               model: "qwen-plus", context: context)
            service.type = dashScopeType
            if let id = service.id?.uuidString { try? TokenManager.setToken(key, for: id) }
        }

        do {
            try context.save()
            // New chats use the router unless the user picks another default in Settings → API Services.
            UserDefaults.standard.set(router.objectID.uriRepresentation().absoluteString, forKey: "defaultApiService")
            UserDefaults.standard.set(router.model, forKey: "gptModel")
            UserDefaults.standard.set(true, forKey: seededKey)
        } catch {
            WardenLog.coreData.error("Seeding Workbench providers failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The router answers `stream: true` with one plain JSON body, which Warden's stream reader drops silently.
    /// Until the router streams, request whole replies from it.
    @MainActor
    private static func disableRouterStreaming(context: NSManagedObjectContext) {
        let request = APIServiceEntity.fetchRequest() as! NSFetchRequest<APIServiceEntity>
        request.predicate = NSPredicate(format: "type == %@ AND useStreamResponse == YES", routerType)
        guard let services = try? context.fetch(request), !services.isEmpty else { return }
        services.forEach { $0.useStreamResponse = false }
        try? context.save()
    }

    @MainActor
    private static func make(name: String, url: URL, model: String, context: NSManagedObjectContext) -> APIServiceEntity {
        let service = APIServiceEntity(context: context)
        service.id = UUID()
        service.name = name
        service.type = "openai_custom"
        service.url = url
        service.model = model
        service.contextSize = 20
        service.useStreamResponse = true
        service.generateChatNames = true
        service.imageUploadsAllowed = false
        service.addedDate = Date()
        service.tokenIdentifier = UUID().uuidString
        return service
    }
}
