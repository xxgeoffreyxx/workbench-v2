import AppKit
import SwiftUI
import WorkbenchKit

/// Queues tool approvals (commands, file writes, patches) and shows them one at a time in the main window.
/// The tool runtime awaits `approve`, so a model's turn simply pauses until the user answers.
@MainActor
final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()

    @Published private(set) var pending: [ApprovalRequest] = []
    private var continuations: [UUID: CheckedContinuation<ApprovalDecision, Never>] = [:]

    var current: ApprovalRequest? { pending.first }

    func request(_ request: ApprovalRequest) async -> ApprovalDecision {
        await withCheckedContinuation { continuation in
            continuations[request.id] = continuation
            pending.append(request)
            WorkbenchHub.shared.refreshActivity()
            WorkbenchNotifier.shared.post(
                .needsApproval,
                title: "Approval needed",
                body: request.summary,
                userInfo: [WorkbenchNotifier.approvalIDKey: request.id.uuidString]
            )
            if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
        }
    }

    func resolve(_ id: UUID, with decision: ApprovalDecision) {
        pending.removeAll { $0.id == id }
        continuations.removeValue(forKey: id)?.resume(returning: decision)
        WorkbenchHub.shared.refreshActivity()
    }

    /// Stopping a reply must not leave a tool call waiting forever.
    func denyAll() {
        for request in pending { resolve(request.id, with: .deny) }
    }
}

/// Bridges the Sendable approver protocol onto the main-actor queue.
struct MainWindowApprover: ToolApprover {
    func approve(_ request: ApprovalRequest) async -> ApprovalDecision {
        await ApprovalCenter.shared.request(request)
    }
}

struct ApprovalSheet: View {
    let request: ApprovalRequest
    let onDecision: (ApprovalDecision) -> Void

    private var kindLabel: String {
        switch request.kind {
        case .command: return "Run a command"
        case .writeFile: return "Write a file"
        case .patch: return "Apply a patch"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: request.kind == .command ? "terminal" : "doc.badge.plus")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kindLabel).font(.headline)
                    Text(request.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            ScrollView {
                Text(request.detail)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 80, maxHeight: 280)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            Label(request.workingDirectory, systemImage: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Button("Deny", role: .cancel) { onDecision(.deny) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if request.kind == .command {
                    Button("Always Allow in Project") { onDecision(.alwaysAllow) }
                        .help("Future commands starting with “\(ApprovalStore.commandPrefix(request.detail))” run without asking in this project")
                }
                Button("Approve") { onDecision(.approve) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// Attach to the main window: presents whichever approval is first in the queue.
struct ApprovalPresenter: ViewModifier {
    @ObservedObject private var center = ApprovalCenter.shared

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { center.current }, set: { _ in })) { request in
            ApprovalSheet(request: request) { decision in
                center.resolve(request.id, with: decision)
            }
        }
    }
}
