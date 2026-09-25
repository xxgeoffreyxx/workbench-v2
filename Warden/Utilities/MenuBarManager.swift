import AppKit
import CoreData
import SwiftUI
import WorkbenchKit

/// The menu bar icon is a status light and a launcher: it shows idle / working / needs-you / error,
/// and its menu lists recent chats, running jobs and model status. The main window is the app.
@MainActor
final class MenuBarManager: NSObject, NSMenuDelegate {
    static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?
    private var activity: WorkbenchHub.Activity = .idle
    private var pulseTimer: Timer?
    private var pulseOn = true

    private override init() {
        super.init()
    }

    func updateVisibility(enabled: Bool) {
        if enabled {
            createStatusItemIfNeeded()
        } else {
            removeStatusItemIfNeeded()
        }
    }

    func createStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        renderIcon()
    }

    func removeStatusItemIfNeeded() {
        stopPulse()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Status icon

    func activityChanged(_ activity: WorkbenchHub.Activity) {
        self.activity = activity
        switch activity {
        case .working, .needsYou: startPulse()
        case .idle, .error: stopPulse()
        }
        renderIcon()
    }

    private var dotColor: NSColor? {
        switch activity {
        case .idle: return nil
        case .working: return .systemBlue
        case .needsYou: return .systemOrange
        case .error: return .systemRed
        }
    }

    private var statusText: String {
        switch activity {
        case .idle: return "Idle"
        case .working(let text), .needsYou(let text), .error(let text): return text
        }
    }

    private func renderIcon() {
        guard let button = statusItem?.button else { return }
        button.toolTip = "Workbench · \(statusText)"
        let base = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "hammer", accessibilityDescription: "Workbench")!
        guard let color = dotColor else {
            base.isTemplate = true
            button.image = base
            return
        }
        // A template image can't carry colour, so draw the glyph in the menu bar's text colour plus a status dot.
        let alpha: CGFloat = pulseOn ? 1 : 0.3
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let glyph = NSImage(size: rect.size, flipped: false) { inner in
                base.draw(in: inner)
                NSColor.labelColor.set()
                inner.fill(using: .sourceAtop)
                return true
            }
            glyph.draw(in: rect)
            color.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 7, y: rect.minY, width: 7, height: 7)).fill()
            return true
        }
        button.image = image
    }

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            Task { @MainActor in
                let manager = MenuBarManager.shared
                manager.pulseOn.toggle()
                manager.renderIcon()
            }
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseOn = true
    }

    // MARK: - Menu

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild(menu) }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let hub = WorkbenchHub.shared

        menu.addItem(disabled(statusText))
        menu.addItem(.separator())
        menu.addItem(item("Open Workbench", #selector(openMainWindow), key: "o"))
        menu.addItem(item("New Chat", #selector(newChat), key: "n"))
        menu.addItem(item("Quick Chat", #selector(openQuickChat)))

        let chats = recentChats()
        if !chats.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Recent chats"))
            for chat in chats {
                let busy = hub.busyChats[chat.id] != nil
                let entry = item((busy ? "● " : "") + (chat.name.isEmpty ? "Untitled" : chat.name), #selector(openChat(_:)))
                entry.representedObject = chat.objectID
                menu.addItem(entry)
            }
        }

        let running = hub.runningJobs
        let shownJobs = running.isEmpty ? Array(hub.jobs.prefix(3)) : Array(running.prefix(6))
        if !shownJobs.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header(running.isEmpty ? "Recent jobs" : "Running jobs"))
            for job in shownJobs {
                let entry = item("\(job.status.symbol) \(job.workflow.rawValue) · \(job.title)", #selector(openJob(_:)))
                entry.representedObject = job.id
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        menu.addItem(header("Models"))
        switch hub.routerOnline {
        case .none:
            menu.addItem(disabled("Router: checking…"))
        case .some(false):
            menu.addItem(disabled("Router offline"))
        case .some(true):
            if hub.residentModels.isEmpty {
                menu.addItem(disabled("Router online · no resident models"))
            }
            for model in hub.residentModels {
                menu.addItem(disabled("\(model.ready ? "●" : "○") \(model.title) · \(model.host)"))
            }
        }
        menu.addItem(item("Refresh Status", #selector(refreshStatus)))

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit Workbench", #selector(quitApp), key: "q"))
    }

    private func recentChats() -> [ChatEntity] {
        let request = ChatEntity.fetchRequest() as! NSFetchRequest<ChatEntity>
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ChatEntity.updatedDate, ascending: false)]
        request.fetchLimit = 6
        return (try? PersistenceController.shared.container.viewContext.fetch(request)) ?? []
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    private func header(_ title: String) -> NSMenuItem {
        NSMenuItem.sectionHeader(title: title)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    // MARK: - Actions

    @objc private func openMainWindow() {
        WorkbenchWindows.showMain()
    }

    @objc private func newChat() {
        WorkbenchWindows.showMain()
        NotificationCenter.default.post(
            name: AppConstants.newChatNotification,
            object: nil,
            userInfo: ["windowId": NSApp.keyWindow?.windowNumber ?? 0]
        )
    }

    @objc private func openChat(_ sender: NSMenuItem) {
        guard let objectID = sender.representedObject as? NSManagedObjectID else { return }
        WorkbenchWindows.showMain()
        NotificationCenter.default.post(name: .openChatByID, object: nil, userInfo: ["chatObjectID": objectID])
    }

    @objc private func openJob(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        WorkbenchWindows.showMain()
        NotificationCenter.default.post(name: .workbenchOpenJob, object: nil, userInfo: ["id": id])
    }

    @objc private func openQuickChat() {
        FloatingPanelManager.shared.openPanel()
    }

    @objc private func refreshStatus() {
        WorkbenchHub.shared.refreshRouter()
        WorkbenchHub.shared.refreshJobs()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindowManager.shared.openSettingsWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

extension JobStatus {
    var symbol: String {
        switch self {
        case .running: return "◐"
        case .complete: return "✓"
        case .failed: return "✕"
        case .needsReview: return "!"
        case .skipped: return "–"
        case .unknown: return "·"
        }
    }
}
