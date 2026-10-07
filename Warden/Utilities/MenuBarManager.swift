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
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let base = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Workbench")!
            .withSymbolConfiguration(config)!
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

    // MARK: - Running indicator pulse

    /// Running items in the open menu; their leading ◐ fades in and out while the menu is open.
    private var runningMenuItems: [NSMenuItem] = []
    private var menuPulseTimer: Timer?
    private var menuPulseBright = true

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menuPulseTimer?.invalidate()
            // A menu tracks events in its own run loop mode, so the timer must run in .common (which includes it).
            let timer = Timer(timeInterval: 0.6, repeats: true) { _ in
                Task { @MainActor in MenuBarManager.shared.pulseRunningItems() }
            }
            RunLoop.main.add(timer, forMode: .common)
            menuPulseTimer = timer
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menuPulseTimer?.invalidate()
            menuPulseTimer = nil
            menuPulseBright = true
        }
    }

    private func pulseRunningItems() {
        menuPulseBright.toggle()
        let color = NSColor.systemOrange.withAlphaComponent(menuPulseBright ? 1 : 0.25)
        for item in runningMenuItems {
            guard let current = item.attributedTitle else { continue }
            let text = NSMutableAttributedString(attributedString: current)
            text.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: 1))
            item.attributedTitle = text
        }
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild(menu) }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        runningMenuItems = []
        let hub = WorkbenchHub.shared

        for slot in MenuLayout.order {
            switch slot {
            case .running: addRunningItems(to: menu, hub: hub)
            case .separator: menu.addItem(.separator())
            case .models: addModels(to: menu, hub: hub)
            case .refreshStatus: menu.addItem(item(slot.title, #selector(refreshStatus)))
            case .open: menu.addItem(item(slot.title, #selector(openMainWindow), key: slot.key))
            case .settings: menu.addItem(item(slot.title, #selector(openSettings), key: slot.key))
            case .quit: menu.addItem(item(slot.title, #selector(quitApp), key: slot.key))
            case .newChat: menu.addItem(item(slot.title, #selector(newChat), key: "n"))
            case .quickChat: menu.addItem(item(slot.title, #selector(openQuickChat)))
            }
        }
    }

    private func addModels(to menu: NSMenu, hub: WorkbenchHub) {
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
            var seen = Set<String>()
            var thermalsShown = Set<String>()
            for model in hub.residentModels where seen.insert("\(model.title)|\(model.host)").inserted {
                menu.addItem(disabled("\(model.ready ? "●" : "○") \(model.title) · \(model.host)"))
                // Thermals once per host, under its first model.
                if thermalsShown.insert(model.host).inserted, let t = hub.thermals[model.host] {
                    menu.addItem(thermalsItem(t))
                }
            }
        }
    }

    /// Replaces the old "N jobs running" line: what is running right now, and chats with a reply not yet read.
    private func addRunningItems(to menu: NSMenu, hub: WorkbenchHub) {
        let feed = MenuFeed.build(jobs: hub.jobs, chats: recentChats().map { chat in
            // Unread is driven by the latest assistant reply only; updatedDate also moves on own sends and
            // project/metadata edits. updatedDate still orders the list.
            let lastReply = ChatReadState.lastAssistantReply(chat.messagesArray.map { ($0.timestamp, $0.own) })
            return MenuFeed.Chat(id: chat.id, title: chat.name, updatedAt: chat.updatedDate,
                                 busy: hub.busyChats[chat.id] != nil,
                                 unread: MenuFeed.isUnread(lastReplyAt: lastReply,
                                                           lastViewedAt: hub.chatLastViewed(chat.id)))
        })
        if feed.items.isEmpty {
            menu.addItem(disabled("Nothing running"))
            return
        }
        for entry in feed.items {
            menu.addItem(runningItem(entry))
        }
        if feed.hasMore {
            menu.addItem(item("View more…", #selector(openJobsTab)))
        }
    }

    private func runningItem(_ entry: MenuFeed.Item) -> NSMenuItem {
        let menuItem: NSMenuItem
        switch entry.target {
        case .job(let id):
            menuItem = item(entry.title, #selector(openJob(_:)))
            menuItem.representedObject = id
        case .chat(let id):
            menuItem = item(entry.title, #selector(openChatByUUID(_:)))
            menuItem.representedObject = id
        }
        let title = entry.title.count > 48 ? String(entry.title.prefix(47)) + "…" : entry.title
        let text = NSMutableAttributedString()
        if entry.marker == .unread {
            text.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: NSColor.systemBlue,
                                                                        .font: NSFont.menuFont(ofSize: 0)]))
        } else if entry.marker == .running {
            text.append(NSAttributedString(string: "◐ ", attributes: [.foregroundColor: NSColor.systemOrange,
                                                                        .font: NSFont.menuFont(ofSize: 0)]))
            runningMenuItems.append(menuItem)
        }
        text.append(NSAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)]))
        text.append(NSAttributedString(string: "   " + entry.detail, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        menuItem.attributedTitle = text
        menuItem.toolTip = entry.title
        return menuItem
    }

    private func thermalsItem(_ t: HostThermals) -> NSMenuItem {
        let entry = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        entry.isEnabled = false
        let font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        let text = NSMutableAttributedString(string: "    ", attributes: [.font: font])
        for (index, part) in t.parts.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            text.append(NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: part.level.nsColor]))
        }
        text.append(NSAttributedString(string: "  · \(t.sampledAt.formatted(date: .omitted, time: .shortened))",
                                       attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        entry.attributedTitle = text
        return entry
    }

    private func recentChats() -> [ChatEntity] {
        let request = ChatEntity.fetchRequest() as! NSFetchRequest<ChatEntity>
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ChatEntity.updatedDate, ascending: false)]
        request.fetchLimit = 40
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

    @objc private func openChatByUUID(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        WorkbenchWindows.showMain()
        NotificationCenter.default.post(name: .workbenchOpenChat, object: nil, userInfo: ["id": id.uuidString])
    }

    @objc private func openJobsTab() {
        WorkbenchWindows.showMain()
        UserDefaults.standard.set(SidebarMode.jobs.rawValue, forKey: "workbench.sidebarMode")
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

extension ThermalLevel {
    var nsColor: NSColor {
        switch self {
        case .normal: return .systemGreen
        case .elevated: return .systemOrange
        case .high: return .systemRed
        }
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
