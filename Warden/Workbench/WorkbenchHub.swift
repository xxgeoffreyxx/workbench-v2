import AppKit
import Combine
import Foundation
import WorkbenchKit

/// App-wide Workbench state: what the menu bar icon shows, the Hosaka jobs feed, and router health.
/// Polls in the background and raises notifications when something changes.
@MainActor
final class WorkbenchHub: ObservableObject {
    static let shared = WorkbenchHub()

    enum Activity: Equatable {
        case idle
        case working(String)
        case needsYou(String)
        case error(String)
    }

    @Published private(set) var activity: Activity = .idle
    @Published private(set) var jobs: [JobRecord] = []
    @Published private(set) var routerOnline: Bool?
    @Published private(set) var routerModels: [RouterModel] = []
    @Published private(set) var residentModels: [ResidentModel] = []
    @Published private(set) var lastRouterError: String?
    @Published var selectedJobID: String?
    /// Latest thermal sample per model host (see HostThermals).
    @Published private(set) var thermals: [String: HostThermals] = [:]
    /// The chat on screen in the main window, so a reply that lands there isn't counted as unread.
    var viewingChatID: UUID? {
        didSet { if let viewingChatID { markChatViewed(viewingChatID) } }
    }
    /// The main chat window, set by ContentView. Read live when a reply finishes, so a closed or minimized
    /// window (or only Settings open) doesn't count as the chat being seen.
    weak var mainChatWindow: NSWindow?

    /// Chats with a reply currently streaming, keyed by chat id.
    @Published private(set) var busyChats: [UUID: String] = [:]

    private var jobTimer: Timer?
    private var routerTimer: Timer?
    private var thermalTimer: Timer?
    private var jobsLoadedOnce = false

    var runningJobs: [JobRecord] { jobs.filter { $0.status == .running } }

    func start() {
        ChatReadState.startup(defaults: TestIsolation.defaults())
        WorkbenchNotifier.shared.start()
        refreshJobs()
        refreshRouter()
        jobTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in WorkbenchHub.shared.refreshJobs() }
        }
        routerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in WorkbenchHub.shared.refreshRouter() }
        }
        refreshThermals()
        thermalTimer = Timer.scheduledTimer(withTimeInterval: HostThermals.pollInterval, repeats: true) { _ in
            Task { @MainActor in WorkbenchHub.shared.refreshThermals() }
        }
    }

    // MARK: - Chats

    func chatStarted(_ id: UUID, name: String) {
        busyChats[id] = name
        // Sending a message touches the chat; that isn't a new reply.
        if viewingChatID == id { markChatViewed(id) }
        refreshActivity()
    }

    func chatFinished(_ id: UUID, name: String, preview: String, failed: Bool = false) {
        busyChats.removeValue(forKey: id)
        // viewingChatID is non-nil only while the Chats tab shows that chat.
        let window = mainChatWindow
        if ChatReadState.shouldMarkFinishedChatViewed(
            finishedChat: id, isActive: NSApp.isActive,
            windowVisible: (window?.isVisible ?? false) && !(window?.isMiniaturized ?? true),
            chatsTabShown: viewingChatID != nil, selectedChat: viewingChatID
        ) {
            markChatViewed(id)
        }
        refreshActivity()
        WorkbenchNotifier.shared.post(
            .replyFinished,
            title: failed ? "Reply failed: \(name)" : name,
            body: preview.isEmpty ? "Reply finished" : preview,
            userInfo: [WorkbenchNotifier.chatIDKey: id.uuidString]
        )
    }

    private static let chatViewedKey = ChatReadState.viewedKey

    /// Read state from UserDefaults; start() sets the baseline before any chat activity.
    private func chatReadState() -> ChatReadState {
        ChatReadState.load(defaults: TestIsolation.defaults())
    }

    func markChatViewed(_ id: UUID, at date: Date = Date()) {
        var state = chatReadState()
        state.markViewed(id.uuidString, at: date)
        TestIsolation.defaults().set(state.viewed, forKey: Self.chatViewedKey)
    }

    /// When the chat was last looked at (see ChatReadState). A lookup writes nothing; only markChatViewed moves it.
    func chatLastViewed(_ id: UUID) -> Date {
        chatReadState().lastViewed(id.uuidString)
    }

    // MARK: - Thermals

    /// Single-flight, deadline and failure backoff live in ThermalSampler; a tick it skips is simply dropped.
    private let thermalSampler = ThermalSampler()

    func refreshThermals() {
        for host in HostThermals.hosts {
            thermalSampler.tick(host: host) { sample in
                guard let sample else { return }
                Task { @MainActor in WorkbenchHub.shared.thermals[host] = sample }
            }
        }
    }

    // MARK: - Jobs

    func refreshJobs() {
        Task.detached(priority: .utility) {
            let fresh = JobFeed.load(includeBenchRuns: UserDefaults.standard.bool(forKey: "workbench.jobs.showBenchRuns"))
            await MainActor.run { WorkbenchHub.shared.apply(jobs: fresh) }
        }
    }

    private func apply(jobs fresh: [JobRecord]) {
        let changes = JobFeed.diff(old: jobs, new: fresh)
        jobs = fresh
        // The first load is a baseline, not news.
        if jobsLoadedOnce {
            for change in changes.prefix(5) {
                let job = change.record
                let from = change.previousStatus.map { "\($0.rawValue) → " } ?? ""
                WorkbenchNotifier.shared.post(
                    .jobChanged,
                    title: "\(job.workflow.rawValue): \(job.title)",
                    body: "\(job.project) · \(from)\(job.status.rawValue)",
                    userInfo: [WorkbenchNotifier.jobIDKey: job.id]
                )
            }
        }
        jobsLoadedOnce = true
        refreshActivity()
    }

    // MARK: - Router

    func refreshRouter() {
        Task {
            do {
                let health = try await RouterClient.shared.health()
                let wasOffline = routerOnline == false
                routerOnline = health.ok
                lastRouterError = nil
                residentModels = await RouterClient.shared.residentModels()
                routerModels = await RouterClient.shared.models()
                if wasOffline {
                    WorkbenchNotifier.shared.post(.routerError, title: "Router is back", body: "The model router answered again.")
                }
            } catch {
                let wasOnline = routerOnline != false
                routerOnline = false
                lastRouterError = error.localizedDescription
                if wasOnline {
                    WorkbenchNotifier.shared.post(
                        .routerError,
                        title: "Router unreachable",
                        body: "\(Workbench.routerBaseURL.absoluteString): \(error.localizedDescription)"
                    )
                }
            }
            refreshActivity()
        }
    }

    func reportModelError(_ message: String) {
        lastRouterError = message
        WorkbenchNotifier.shared.post(.routerError, title: "Model error", body: message)
        refreshActivity()
    }

    // MARK: - Activity

    func refreshActivity() {
        let next: Activity
        if let approval = ApprovalCenter.shared.current {
            next = .needsYou(approval.summary)
        } else if !busyChats.isEmpty {
            next = .working(busyChats.count == 1 ? "Replying: \(busyChats.values.first ?? "")" : "\(busyChats.count) replies running")
        } else if routerOnline == false {
            next = .error(lastRouterError ?? "Router unreachable")
        } else if !runningJobs.isEmpty {
            next = .working("\(runningJobs.count) job\(runningJobs.count == 1 ? "" : "s") running")
        } else {
            next = .idle
        }
        if next != activity {
            activity = next
            MenuBarManager.shared.activityChanged(next)
        }
    }
}
