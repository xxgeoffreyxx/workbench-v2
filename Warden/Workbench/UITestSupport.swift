import CoreData
import Foundation

/// Hooks used only by the UI tests, switched on by launch arguments so a normal launch never touches them.
/// `-WorkbenchTestProjectFolder <path>` creates (once) a project named "UITest Project" linked to that folder.
enum UITestSupport {
    static let projectName = "UITest Project"

    @MainActor
    static func apply(context: NSManagedObjectContext) {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-WorkbenchTestProjectFolder"), flag + 1 < args.count else { return }
        let folder = URL(fileURLWithPath: args[flag + 1], isDirectory: true)

        let request = ProjectEntity.fetchRequest() as! NSFetchRequest<ProjectEntity>
        request.predicate = NSPredicate(format: "name == %@", projectName)
        let project = (try? context.fetch(request))?.first ?? {
            let project = ProjectEntity(context: context)
            project.id = UUID()
            project.name = projectName
            project.createdAt = Date()
            project.updatedAt = Date()
            project.isArchived = false
            return project
        }()
        try? context.save()
        ProjectFolders.shared.setFolder(folder, for: project)
    }
}
