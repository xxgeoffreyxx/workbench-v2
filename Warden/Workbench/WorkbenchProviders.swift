import CoreData
import Foundation
import WorkbenchKit

/// Seeds the providers Workbench needs on first launch: the local model router (Helga and the resident models)
/// and, when a DashScope key is configured, Alibaba's cloud fallback. Both use Warden's OpenAI-compatible handler,
/// so they get streaming, tools and the model picker for free.
enum WorkbenchProviders {
    static let routerName = "Workbench Router"
    static let dashScopeName = "DashScope"
    private static let seededKey = "workbench.providersSeeded.v1"

    @MainActor
    static func ensureDefaults(context: NSManagedObjectContext) {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }

        let request = APIServiceEntity.fetchRequest() as! NSFetchRequest<APIServiceEntity>
        let existing = (try? context.fetch(request)) ?? []
        let names = Set(existing.compactMap(\.name))

        if !names.contains(routerName) {
            let router = make(
                name: routerName,
                url: Workbench.routerBaseURL.appendingPathComponent("chat/completions"),
                model: RouterModel.defaults.first?.modelID ?? "ornith",
                context: context
            )
            // The router is the default service for new chats.
            router.defaultAgent = 1
        }

        if !names.contains(dashScopeName), let key = DashScope.apiKey() {
            let service = make(
                name: dashScopeName,
                url: URL(string: DashScope.baseURL + "/chat/completions")!,
                model: "qwen-plus",
                context: context
            )
            if let id = service.id?.uuidString { try? TokenManager.setToken(key, for: id) }
        }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: seededKey)
        } catch {
            WardenLog.coreData.error("Seeding Workbench providers failed: \(error.localizedDescription, privacy: .public)")
        }
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
