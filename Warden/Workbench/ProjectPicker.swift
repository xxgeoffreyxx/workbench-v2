import AppKit
import CoreData
import SwiftUI

/// Composer control for choosing the chat's project, like Bench's workspace picker. A project with a linked folder
/// gives the chat Workbench's file, command and skill tools inside that folder.
struct ProjectPickerButton: View {
    @ObservedObject var chat: ChatEntity
    @Environment(\.managedObjectContext) private var context
    @ObservedObject private var folders = ProjectFolders.shared

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ProjectEntity.sortOrder, ascending: true)],
        predicate: NSPredicate(format: "isArchived == NO")
    )
    private var projects: FetchedResults<ProjectEntity>

    private var label: String {
        guard let project = chat.project else { return "No project" }
        return project.name ?? "Project"
    }

    var body: some View {
        Menu {
            Button {
                assign(nil)
            } label: {
                if chat.project == nil { Label("No project", systemImage: "checkmark") } else { Text("No project") }
            }
            if !projects.isEmpty { Divider() }
            ForEach(projects, id: \.objectID) { project in
                Button {
                    assign(project)
                } label: {
                    let title = (project.name ?? "Project") + (folders.folder(for: project) == nil ? "" : " — \(folders.folder(for: project)!.lastPathComponent)")
                    if chat.project == project { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
            Divider()
            Button("New Project from Folder…", action: newProjectFromFolder)
            if let project = chat.project, folders.folder(for: project) == nil {
                Button("Link Folder to “\(project.name ?? "Project")”…") { linkFolder(to: project) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: folders.folder(for: chat.project) != nil ? "folder.fill" : "folder")
                Text(label).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(chat.project == nil ? .secondary : .primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(folders.folder(for: chat.project)?.path ?? "Choose a project for this chat")
    }

    private func assign(_ project: ProjectEntity?) {
        chat.project = project
        project?.updatedAt = Date()
        try? context.save()
    }

    private func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func newProjectFromFolder() {
        guard let url = chooseFolder(prompt: "Create Project") else { return }
        // Reuse a project already linked to this folder.
        if let existing = projects.first(where: { folders.folder(for: $0)?.standardizedFileURL == url.standardizedFileURL }) {
            assign(existing)
            return
        }
        let project = ProjectEntity(context: context)
        project.id = UUID()
        project.name = url.lastPathComponent
        project.createdAt = Date()
        project.updatedAt = Date()
        project.sortOrder = Int32(projects.count)
        project.isArchived = false
        folders.setFolder(url, for: project)
        assign(project)
    }

    private func linkFolder(to project: ProjectEntity) {
        guard let url = chooseFolder(prompt: "Link Folder") else { return }
        folders.setFolder(url, for: project)
    }
}
