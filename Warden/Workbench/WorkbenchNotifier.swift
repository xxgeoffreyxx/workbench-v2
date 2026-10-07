import AppKit
import Foundation
import UserNotifications

/// The kinds of alert Workbench can raise. Each one has its own switch in Settings → Notifications.
enum WorkbenchAlert: String, CaseIterable, Identifiable {
    case replyFinished
    case needsApproval
    case jobChanged
    case routerError

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replyFinished: return "Reply finished"
        case .needsApproval: return "Needs approval or input"
        case .jobChanged: return "Hosaka job changes"
        case .routerError: return "Model and router errors"
        }
    }

    var detail: String {
        switch self {
        case .replyFinished: return "A reply finished while Workbench wasn't the front app."
        case .needsApproval: return "A command, file write or patch is waiting for you."
        case .jobChanged: return "A task, Helga or peer review finished, failed or changed stage."
        case .routerError: return "The router went down, or a model failed to load or warm up."
        }
    }

    var defaultsKey: String { "workbench.alert.\(rawValue)" }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }
}

/// Posts user notifications and routes clicks back to the right chat or job.
@MainActor
final class WorkbenchNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WorkbenchNotifier()

    static let chatIDKey = "chatID"
    static let jobIDKey = "jobID"
    static let approvalIDKey = "approvalID"

    private var authorized = false

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    /// Replies only notify when the user isn't looking at Workbench; everything else always notifies.
    func post(_ alert: WorkbenchAlert, title: String, body: String, userInfo: [String: String] = [:]) {
        guard alert.isEnabled else { return }
        if alert == .replyFinished && NSApp.isActive { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(240))
        content.sound = alert == .needsApproval ? .default : nil
        content.threadIdentifier = alert.rawValue
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run {
            WorkbenchWindows.showMain()
            if let chatID = info[Self.chatIDKey] as? String {
                NotificationCenter.default.post(name: .workbenchOpenChat, object: nil, userInfo: ["id": chatID])
            } else if let jobID = info[Self.jobIDKey] as? String {
                NotificationCenter.default.post(name: .workbenchOpenJob, object: nil, userInfo: ["id": jobID])
            }
        }
    }
}

extension Notification.Name {
    static let workbenchOpenChat = Notification.Name("workbenchOpenChat")
    static let workbenchOpenJob = Notification.Name("workbenchOpenJob")
}

enum WorkbenchWindows {
    /// Brings the main window forward, reopening it if the user closed it.
    @MainActor
    static func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.frameAutosaveName == "MainWindow" }) {
            window.makeKeyAndOrderFront(nil)
        } else if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
        }
    }
}
