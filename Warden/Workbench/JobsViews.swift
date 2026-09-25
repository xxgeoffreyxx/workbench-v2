import AppKit
import SwiftUI
import WorkbenchKit

enum SidebarMode: String, CaseIterable, Identifiable {
    case chats = "Chats"
    case jobs = "Jobs"
    var id: String { rawValue }
}

extension JobStatus {
    var color: Color {
        switch self {
        case .running: return .blue
        case .complete: return .green
        case .failed: return .red
        case .needsReview: return .orange
        case .skipped, .unknown: return .secondary
        }
    }

    var label: String {
        switch self {
        case .needsReview: return "Needs review"
        default: return rawValue.capitalized
        }
    }
}

/// Sidebar list of Hosaka tasks, Helga and peer reviews, RL Studio runs and live benchmarks, grouped by project.
struct JobsListView: View {
    @ObservedObject private var hub = WorkbenchHub.shared
    @State private var workflow: String = "All"
    @State private var query = ""

    private var filtered: [JobRecord] {
        hub.jobs.filter { job in
            (workflow == "All" || job.workflow.rawValue == workflow)
                && (query.isEmpty || job.title.localizedCaseInsensitiveContains(query)
                    || job.project.localizedCaseInsensitiveContains(query))
        }
    }

    private var grouped: [(String, [JobRecord])] {
        let groups = Dictionary(grouping: filtered, by: \.project)
        return groups.keys.sorted().map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search jobs", text: $query).textFieldStyle(.plain)
            }
            .padding(7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10)

            Picker("", selection: $workflow) {
                Text("All").tag("All")
                ForEach(JobWorkflow.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)

            List(selection: $hub.selectedJobID) {
                if filtered.isEmpty {
                    Text(hub.jobs.isEmpty ? "No jobs found yet." : "No jobs match.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(grouped, id: \.0) { project, jobs in
                    Section(project) {
                        ForEach(jobs) { job in
                            JobRowView(job: job).tag(job.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            HStack {
                Text("\(hub.runningJobs.count) running · \(hub.jobs.count) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    hub.refreshJobs()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh jobs")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}

struct JobRowView: View {
    let job: JobRecord

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(job.status.color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).lineLimit(2)
                HStack(spacing: 4) {
                    Text(job.workflow.rawValue)
                    Text("·")
                    Text(job.updatedAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct JobDetailView: View {
    let job: JobRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(job.status.label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(job.status.color.opacity(0.15), in: Capsule())
                            .foregroundStyle(job.status.color)
                        Text(job.workflow.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(job.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    meta("Project", job.project)
                    if let model = job.model { meta("Model", model) }
                    if let host = job.host { meta("Host", host) }
                    meta("Updated", job.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    if job.eventCount > 0 { meta("Events", "\(job.eventCount)") }
                }
                .font(.callout)

                HStack {
                    if let task = job.taskPath { reveal("Task folder", task) }
                    if let artifact = job.artifactPath { reveal("Artifact", artifact) }
                }

                if !job.summary.isEmpty {
                    section("Summary") {
                        Text(job.summary).textSelection(.enabled)
                    }
                }
                if !job.output.isEmpty {
                    section("Output") {
                        Text(job.output)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func meta(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func reveal(_ title: String, _ path: String) -> some View {
        Button {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        } label: {
            Label(title, systemImage: "folder")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

struct JobsEmptyDetail: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Select a job").font(.title3)
            Text("Hosaka tasks, Helga and peer reviews, and research runs show up here.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
