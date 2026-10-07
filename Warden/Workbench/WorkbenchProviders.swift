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
        upgradeToV3(context: context)
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }

        let request = APIServiceEntity.fetchRequest() as! NSFetchRequest<APIServiceEntity>
        let existing = (try? context.fetch(request)) ?? []

        // v1 seeded both as "openai_custom"; move them onto their own types.
        let router = existing.first { $0.type == routerType || $0.name == routerName }
            ?? make(name: routerName, url: Workbench.routerBaseURL.appendingPathComponent("chat/completions"),
                    model: RouterModel.defaults.first?.modelID ?? "ornith", context: context)
        router.type = routerType

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

    /// v3: the router streams now (patched 2026-09-25), so turn streaming back on for it, and add pi / oh-my-pi
    /// services for whichever agent CLIs are installed.
    @MainActor
    private static func upgradeToV3(context: NSManagedObjectContext) {
        let key = "workbench.providersSeeded.v3"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let request = APIServiceEntity.fetchRequest() as! NSFetchRequest<APIServiceEntity>
        let existing = (try? context.fetch(request)) ?? []
        existing.filter { $0.type == routerType }.forEach { $0.useStreamResponse = true }
        for cli in AgentCLI.allCases where cli.executableURL != nil && !existing.contains(where: { $0.type == cli.rawValue }) {
            let service = make(name: cli.displayName, url: URL(string: "stdio://\(cli.executableName)")!,
                               model: "workbench/ornith", context: context)
            service.type = cli.rawValue
            service.generateChatNames = false
        }
        if (try? context.save()) != nil { UserDefaults.standard.set(true, forKey: key) }
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
