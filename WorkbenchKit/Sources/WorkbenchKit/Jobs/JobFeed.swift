import Foundation

// Ported from model-workbench/Sources/main.swift (job feed). Behaviour kept identical.

public enum JobWorkflow: String, Codable, CaseIterable, Hashable, Sendable {
    case background = "Background"
    case peer = "Peer"
    case helga = "Helga"
}

public enum JobStatus: String, Codable, Hashable, Sendable {
    case running
    case complete
    case failed
    case needsReview = "needs_review"
    case skipped
    case unknown
}

public struct JobEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var jobID: String
    public var timestamp: Date
    public var project: String
    public var workflow: JobWorkflow
    public var status: JobStatus
    public var title: String
    public var model: String?
    public var host: String?
    public var taskPath: String?
    public var artifactPath: String?
    public var summary: String?
    public var output: String?

    public init(
        id: UUID = UUID(),
        jobID: String,
        timestamp: Date = Date(),
        project: String,
        workflow: JobWorkflow,
        status: JobStatus,
        title: String,
        model: String? = nil,
        host: String? = nil,
        taskPath: String? = nil,
        artifactPath: String? = nil,
        summary: String? = nil,
        output: String? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.timestamp = timestamp
        self.project = project
        self.workflow = workflow
        self.status = status
        self.title = title
        self.model = model
        self.host = host
        self.taskPath = taskPath
        self.artifactPath = artifactPath
        self.summary = summary
        self.output = output
    }
}

public struct JobRecord: Identifiable, Hashable, Sendable {
    public var id: String
    public var project: String
    public var workflow: JobWorkflow
    public var status: JobStatus
    public var title: String
    public var model: String?
    public var host: String?
    public var taskPath: String?
    public var artifactPath: String?
    public var summary: String
    public var output: String
    public var updatedAt: Date
    public var eventCount: Int

    public init(id: String, project: String, workflow: JobWorkflow, status: JobStatus, title: String, model: String?, host: String?, taskPath: String?, artifactPath: String?, summary: String, output: String, updatedAt: Date, eventCount: Int) {
        self.id = id
        self.project = project
        self.workflow = workflow
        self.status = status
        self.title = title
        self.model = model
        self.host = host
        self.taskPath = taskPath
        self.artifactPath = artifactPath
        self.summary = summary
        self.output = output
        self.updatedAt = updatedAt
        self.eventCount = eventCount
    }
}

public struct ProcessSnapshot: Hashable, Sendable {
    public let pid: String
    public let elapsed: String
    public let command: String

    public init(pid: String, elapsed: String, command: String) {
        self.pid = pid
        self.elapsed = elapsed
        self.command = command
    }
}

/// A record that is new, or whose status differs from the previous snapshot.
public struct JobChange: Hashable, Sendable {
    public let record: JobRecord
    /// nil when the record did not exist before.
    public let previousStatus: JobStatus?

    public init(record: JobRecord, previousStatus: JobStatus?) {
        self.record = record
        self.previousStatus = previousStatus
    }
}

struct JobCommandResult {
    let exitCode: Int32
    let output: String
}

public enum JobFeed {
    /// Loads every job record: artifacts on disk, live processes and the jobs.jsonl event log.
    public static func load() -> [JobRecord] { load(includeBenchRuns: false) }

    /// Benchmark harness runs live under `.bench-runs` and log a start event per run but rarely a finish, so they
    /// would flood the feed with jobs stuck at "running". They're hidden unless asked for.
    /// A job whose last event is "running" and older than `staleAfter` is reported as `.unknown` (stale).
    public static func load(includeBenchRuns: Bool, staleAfter: TimeInterval = 6 * 3600, now: Date = Date()) -> [JobRecord] {
        clean(loadJobRecords(), includeBenchRuns: includeBenchRuns, staleAfter: staleAfter, now: now)
    }

    static func clean(_ records: [JobRecord], includeBenchRuns: Bool, staleAfter: TimeInterval, now: Date) -> [JobRecord] {
        records.compactMap { record in
            if !includeBenchRuns, isBenchRun(record) { return nil }
            var record = record
            // Live process records are refreshed on every load, so they never go stale.
            if record.status == .running, now.timeIntervalSince(record.updatedAt) > staleAfter, !record.id.hasPrefix("process:") {
                record.status = .unknown
                let hours = Int(now.timeIntervalSince(record.updatedAt) / 3600)
                record.summary = "No update for \(hours)h; the job probably stopped without reporting. Last event: \(record.summary)"
            }
            return record
        }
    }

    /// Bench harness runs, and Helga test-harness fixtures (pass/reject/error-task) that live in temp directories.
    static func isBenchRun(_ record: JobRecord) -> Bool {
        [record.taskPath, record.artifactPath].contains { path in
            guard let path else { return false }
            return path.contains("/.bench-runs/") || tempPrefixes.contains { path.hasPrefix($0) }
        }
    }

    static let tempPrefixes = ["/var/folders/", "/private/var/folders/", "/tmp/", "/private/tmp/"]

    /// Workflow plus task/run id, case-insensitive, so "scout:peer:adhoc-1" and "Scout:peer:adhoc-1" are one job.
    static func dedupeKey(workflow: JobWorkflow, id: String, taskPath: String?) -> String {
        let taskID = taskPath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? id.split(separator: ":").last.map(String.init) ?? id
        return "\(workflow.rawValue):\(taskID)".lowercased()
    }

    /// What a job's folder holds, for jobs that recorded no output: the files, and the tail of the newest log.
    public static func folderPreview(path: String, maxFiles: Int = 25) -> String? {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return nil }
        let sorted = items.sorted { newestFirst($0, $1) }
        var lines = ["Files in \(folder.path):"] + sorted.prefix(maxFiles).map { "  " + $0.lastPathComponent }
        if sorted.count > maxFiles { lines.append("  … \(sorted.count - maxFiles) more") }
        if let log = sorted.first(where: { ["log", "txt", "md", "json"].contains($0.pathExtension) }) {
            lines += ["", "Tail of \(log.lastPathComponent):", readTailText(log, limit: 3000)]
        }
        return lines.joined(separator: "\n")
    }

    /// Records that are new or whose status changed between two snapshots (in `new` order).
    public static func diff(old: [JobRecord], new: [JobRecord]) -> [JobChange] {
        let previous = Dictionary(old.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        return new.compactMap { record in
            guard let before = previous[record.id] else { return JobChange(record: record, previousStatus: nil) }
            return before == record.status ? nil : JobChange(record: record, previousStatus: before)
        }
    }

    /// Where job events are appended (the app's support directory).
    public static var jobsURL: URL {
        Workbench.supportDirectory.appendingPathComponent("jobs.jsonl")
    }

    /// Event logs read by the feed: the current one plus the paths Bench / ModelWorkbench used,
    /// so existing events keep showing. Duplicate paths are dropped.
    public static var jobsURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            jobsURL,
            home.appendingPathComponent("Library/Application Support/Workbench/jobs.jsonl"),
            home.appendingPathComponent("Library/Application Support/ModelWorkbench/jobs.jsonl"),
        ]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
    }

    static func jobEvents() -> [JobEvent] {
        var seenIDs = Set<UUID>()
        return jobsURLs.flatMap { jobEvents(at: $0) }.filter { seenIDs.insert($0.id).inserted }
    }

    static func runCommand(_ executable: String, _ arguments: [String]) -> JobCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return JobCommandResult(exitCode: process.terminationStatus, output: output)
        } catch {
            return JobCommandResult(exitCode: 127, output: error.localizedDescription)
        }
    }

    static func limit(_ text: String, characters: Int) -> String {
        if text.count <= characters { return text }
        return String(text.prefix(characters)) + "\n...truncated..."
    }

    static func loadJobRecords() -> [JobRecord] {
        merge(artifacts: artifactJobRecords(), events: jobEvents())
    }

    /// Overlays jobs.jsonl events on the records read from disk. When a job has evidence on disk, its title, summary
    /// and output come from that evidence (events carry only a short title like "Requirements Contract" and a one-line
    /// verdict); the event decides the status only while it is newer than the evidence, e.g. a re-run in progress.
    static func merge(artifacts: [JobRecord], events: [JobEvent], projectRoots: [String: URL]? = nil,
                      runsRoot: String? = nil) -> [JobRecord] {
        var recordsByID: [String: JobRecord] = [:]
        var artifactsByID: [String: JobRecord] = [:]
        var idByKey: [String: String] = [:]
        for record in artifacts {
            recordsByID[record.id] = record
            artifactsByID[record.id] = record
            idByKey[dedupeKey(workflow: record.workflow, id: record.id, taskPath: record.taskPath)] = record.id
        }
        for var event in events {
            if recordsByID[event.jobID] == nil,
               let known = idByKey[dedupeKey(workflow: event.workflow, id: event.jobID, taskPath: event.taskPath)] {
                event.jobID = known
            }
            let existing = recordsByID[event.jobID]
            if artifactsByID[event.jobID] == nil, event.workflow != .background,
               let found = evidenceRecord(for: event, projectRoots: projectRoots, runsRoot: runsRoot ?? hosakaRunsRoot) {
                // The event's stored path was relative or stale (the task moved stage); read the evidence where it is now.
                artifactsByID[event.jobID] = found
            }
            let artifact = artifactsByID[event.jobID]
            let eventOutput = artifact == nil ? (event.output ?? eventArtifactOutput(for: event)) : nil
            let eventIsNewer = artifact.map { event.timestamp > $0.updatedAt } ?? true
            recordsByID[event.jobID] = JobRecord(
                id: event.jobID,
                project: artifact?.project ?? event.project,
                workflow: event.workflow,
                status: eventIsNewer ? event.status : (artifact?.status ?? event.status),
                title: artifact?.title ?? event.title,
                model: event.model ?? existing?.model,
                host: event.host ?? existing?.host,
                taskPath: artifact?.taskPath ?? event.taskPath ?? existing?.taskPath,
                artifactPath: artifact?.artifactPath ?? event.artifactPath ?? existing?.artifactPath,
                summary: artifact.flatMap { eventIsNewer && event.status == .running ? nil : $0.summary }
                    ?? event.summary ?? existing?.summary ?? event.status.rawValue,
                output: artifact?.output ?? eventOutput ?? existing.flatMap { $0.output.isEmpty ? nil : $0.output }
                    ?? eventFallbackOutput(event),
                updatedAt: max(event.timestamp, existing?.updatedAt ?? .distantPast),
                eventCount: (existing?.eventCount ?? 0) + 1
            )
        }
        return sortedByTime(Array(recordsByID.values))
    }

    /// Newest first, strictly by time; ties broken by title. No project or workflow ranking.
    public static func sortedByTime(_ records: [JobRecord]) -> [JobRecord] {
        records.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    static func jobEvents(at url: URL) -> [JobEvent] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
            return try? decoder.decode(JobEvent.self, from: data)
        }
    }

    static let taskStages = ["_staging", "backlog", "in-progress", "code-complete", "dev-complete", "done", "failed"]

    /// Where an event's task lives now. Stored paths may be relative to the project ("tasks/code-complete/803b") or
    /// stale because the task moved stage, so this tries the path as given, then the same task id under every
    /// tasks/<stage>/ folder, then under the Hosaka runs folder for ad-hoc runs.
    static func resolveTaskURL(taskPath: String?, artifactPath: String?, project: String,
                               projectRoots: [String: URL]?, runsRoot: String) -> URL? {
        let fm = FileManager.default
        let root = projectRoots.map { $0[project.lowercased()] } ?? projectRoot(for: project)
        var taskID: String?
        if let taskPath {
            let direct = taskPath.hasPrefix("/") ? URL(fileURLWithPath: taskPath) : root?.appendingPathComponent(taskPath)
            if let direct, fm.fileExists(atPath: direct.path) { return direct }
            taskID = URL(fileURLWithPath: taskPath).lastPathComponent
        } else if let artifactPath {
            // ".../tasks/<stage>/<id>/evidence/x.json" or ".../<run-id>/evidence/x.json": the id is above evidence/.
            let parts = URL(fileURLWithPath: artifactPath).pathComponents
            if let index = parts.lastIndex(of: "evidence"), index > 0 { taskID = parts[index - 1] }
        }
        guard let taskID, !taskID.isEmpty, taskID != "/" else { return nil }
        var candidates: [URL] = []
        if let root { candidates += taskStages.map { root.appendingPathComponent("tasks/\($0)/\(taskID)") } }
        let runs = URL(fileURLWithPath: runsRoot)
        candidates.append(runs.appendingPathComponent("\(project.lowercased())/\(taskID)"))
        if let projects = try? fm.contentsOfDirectory(atPath: runsRoot) {
            candidates += projects.map { runs.appendingPathComponent("\($0)/\(taskID)") }
        }
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    /// A Helga or Peer record read from the evidence of the task an event points at, wherever that task is now.
    static func evidenceRecord(for event: JobEvent, projectRoots: [String: URL]?, runsRoot: String) -> JobRecord? {
        guard let taskURL = resolveTaskURL(taskPath: event.taskPath, artifactPath: event.artifactPath, project: event.project,
                                           projectRoots: projectRoots, runsRoot: runsRoot) else { return nil }
        let fm = FileManager.default
        let evidence = taskURL.appendingPathComponent("evidence", isDirectory: true)
        let title = taskTitle(taskURL: taskURL) ?? event.title
        var record: JobRecord?
        switch event.workflow {
        case .helga:
            let json = evidence.appendingPathComponent("helga-verdict.json")
            let log = evidence.appendingPathComponent("helga-run.log")
            guard fm.fileExists(atPath: json.path) || fm.fileExists(atPath: log.path) else { return nil }
            record = helgaRecord(project: event.project, taskName: taskURL.lastPathComponent, title: title, taskURL: taskURL,
                                 jsonURL: json, logURL: log)
        case .peer:
            let json = evidence.appendingPathComponent("code-review-result.json")
            let summary = evidence.appendingPathComponent("review-summary.md")
            guard fm.fileExists(atPath: json.path) || fm.fileExists(atPath: summary.path) else { return nil }
            record = reviewRecord(project: event.project, taskName: taskURL.lastPathComponent, title: title, taskURL: taskURL,
                                  jsonURL: json, summaryURL: summary)
        case .background:
            return nil
        }
        record?.id = event.jobID
        return record
    }

    /// What to show when a job's evidence can't be found anywhere: everything the event itself recorded.
    static func eventFallbackOutput(_ event: JobEvent) -> String {
        [
            "No evidence found on disk for this job; showing what its last event recorded.",
            "Status: \(event.status.rawValue)",
            event.summary.map { "Summary: \($0)" },
            event.model.map { "Model: \($0)" },
            event.taskPath.map { "Task path: \($0)" },
            event.artifactPath.map { "Artifact: \($0)" },
        ].compactMap { $0 }.joined(separator: "\n")
    }

    static func eventArtifactOutput(for event: JobEvent) -> String? {
        guard let path = event.artifactPath,
              let url = resolvedArtifactURL(path: path, project: event.project, taskPath: event.taskPath),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return readText(url, limit: 18_000)
    }

    static func resolvedArtifactURL(path: String, project: String, taskPath: String?) -> URL? {
        let url = URL(fileURLWithPath: path)
        if url.path == path, path.hasPrefix("/") {
            return url
        }

        if let taskPath, taskPath.hasPrefix("/") {
            let taskURL = URL(fileURLWithPath: taskPath)
            let candidate = taskURL.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        guard let root = projectRoot(for: project) else { return nil }
        return root.appendingPathComponent(path)
    }

    static func projectRoot(for project: String) -> URL? {
        switch project.lowercased() {
        case "scout":
            return URL(fileURLWithPath: "/Users/geoffmccaleb/scout")
        case "thriveos":
            return URL(fileURLWithPath: "/Users/geoffmccaleb/ThriveOS")
        case "rl":
            return URL(fileURLWithPath: "/Users/geoffmccaleb/RL")
        default:
            return nil
        }
    }

    static func artifactJobRecords() -> [JobRecord] {
        var records: [JobRecord] = []
        records.append(contentsOf: hosakaArtifactRecords(project: "Scout", root: "/Users/geoffmccaleb/scout"))
        records.append(contentsOf: hosakaArtifactRecords(project: "ThriveOS", root: "/Users/geoffmccaleb/ThriveOS"))
        records.append(contentsOf: hosakaRunRecords(runsRoot: hosakaRunsRoot))
        records.append(contentsOf: rlArtifactRecords(root: "/Users/geoffmccaleb/RL"))
        records.append(contentsOf: activeProcessJobRecords())
        return records
    }

    static func activeProcessJobRecords() -> [JobRecord] {
        var recordsByID: [String: JobRecord] = [:]
        for process in processSnapshots() {
            if let record = agenticBenchmarkProcessRecord(process) {
                recordsByID[record.id] = record
            }
            if let record = agenticBenchmarkLauncherRecord(process) {
                recordsByID[record.id] = record
            }
        }
        return Array(recordsByID.values)
    }

    static func processSnapshots() -> [ProcessSnapshot] {
        let result = runCommand("/bin/ps", ["axo", "pid,ppid,stat,etime,command"])
        guard result.exitCode == 0 else { return [] }
        return result.output.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("PID") else { return nil }
            let parts = trimmed.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5 else { return nil }
            return ProcessSnapshot(pid: String(parts[0]), elapsed: String(parts[3]), command: String(parts[4]))
        }
    }

    static func agenticBenchmarkProcessRecord(_ process: ProcessSnapshot) -> JobRecord? {
        guard process.command.contains("agentic-coding-bench.mjs") else { return nil }
        let outputPath = commandArgument(after: "--out", in: process.command)
        let models = commandArgument(after: "--models", in: process.command)
        let outputURL = outputPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let artifactURL = outputURL.flatMap(agenticBenchmarkArtifactURL)
        let output = activeProcessOutput(process: process, artifactURL: artifactURL)
        let idSuffix = outputPath ?? process.pid
        return JobRecord(
            id: "Scout:background:agentic-coding:\(idSuffix)",
            project: "Scout",
            workflow: .background,
            status: .running,
            title: "Agentic coding benchmark",
            model: models,
            host: nil,
            taskPath: outputPath ?? "/Users/geoffmccaleb/scout",
            artifactPath: artifactURL?.path,
            summary: "Running \(process.elapsed) · PID \(process.pid)\(models.map { " · \($0)" } ?? "")",
            output: output,
            updatedAt: Date(),
            eventCount: 0
        )
    }

    static func agenticBenchmarkLauncherRecord(_ process: ProcessSnapshot) -> JobRecord? {
        guard process.command.contains("run-agentic-benchmark"),
              !process.command.contains("agentic-coding-bench.mjs"),
              let scriptPath = commandToken(containing: "run-agentic-benchmark", in: process.command) else {
            return nil
        }
        let scriptURL = URL(fileURLWithPath: scriptPath)
        let runURL = scriptURL.deletingLastPathComponent()
        let artifactURL = agenticBenchmarkArtifactURL(for: runURL)
            ?? runURL.appendingPathComponent("launcher.log")
        let output = activeProcessOutput(process: process, artifactURL: FileManager.default.fileExists(atPath: artifactURL.path) ? artifactURL : nil)
        return JobRecord(
            id: "Scout:background:agentic-coding-launcher:\(runURL.path)",
            project: "Scout",
            workflow: .background,
            status: .running,
            title: "Agentic coding benchmark launcher",
            model: nil,
            host: nil,
            taskPath: runURL.path,
            artifactPath: FileManager.default.fileExists(atPath: artifactURL.path) ? artifactURL.path : scriptURL.path,
            summary: "Running \(process.elapsed) · PID \(process.pid)",
            output: output,
            updatedAt: Date(),
            eventCount: 0
        )
    }

    static func agenticBenchmarkArtifactURL(for outputURL: URL) -> URL? {
        [
            outputURL.appendingPathComponent("agentic-coding-summary.md"),
            outputURL.appendingPathComponent("agentic-coding.stream.jsonl"),
            outputURL.appendingPathComponent("run.log"),
            outputURL.appendingPathComponent("launcher.log"),
        ].first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func activeProcessOutput(process: ProcessSnapshot, artifactURL: URL?) -> String {
        let header = "PID \(process.pid) · running \(process.elapsed)\n\nCommand:\n\(process.command)"
        guard let artifactURL else { return header }
        let artifactText = readTailText(artifactURL, limit: 18_000)
        guard !artifactText.isEmpty else { return header }
        return "\(header)\n\n\(artifactText)"
    }

    static func commandArgument(after option: String, in command: String) -> String? {
        let tokens = commandTokens(command)
        for (index, token) in tokens.enumerated() {
            if token == option, index + 1 < tokens.count {
                return tokens[index + 1]
            }
            if token.hasPrefix("\(option)=") {
                return String(token.dropFirst(option.count + 1))
            }
        }
        return nil
    }

    static func commandToken(containing needle: String, in command: String) -> String? {
        commandTokens(command).first { $0.contains(needle) }
    }

    static func commandTokens(_ command: String) -> [String] {
        command.split(separator: " ").map { token in
            String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }

    static func hosakaArtifactRecords(project: String, root: String) -> [JobRecord] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        let tasksURL = rootURL.appendingPathComponent("tasks", isDirectory: true)
        guard fm.fileExists(atPath: tasksURL.path) else { return [] }

        let stages = ["_staging", "backlog", "in-progress", "code-complete", "dev-complete", "done", "failed"]
        var records: [JobRecord] = []
        for stage in stages {
            let stageURL = tasksURL.appendingPathComponent(stage, isDirectory: true)
            guard let taskURLs = try? fm.contentsOfDirectory(
                at: stageURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for taskURL in taskURLs {
                guard ((try? taskURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) else { continue }
                let taskName = taskURL.lastPathComponent
                let title = taskTitle(taskURL: taskURL) ?? taskName
                let evidenceURL = taskURL.appendingPathComponent("evidence", isDirectory: true)
                let reviewJSON = evidenceURL.appendingPathComponent("code-review-result.json")
                let reviewSummary = evidenceURL.appendingPathComponent("review-summary.md")
                if fm.fileExists(atPath: reviewJSON.path) || fm.fileExists(atPath: reviewSummary.path) {
                    records.append(reviewRecord(project: project, taskName: taskName, title: title, taskURL: taskURL, jsonURL: reviewJSON, summaryURL: reviewSummary))
                }

                let helgaJSON = evidenceURL.appendingPathComponent("helga-verdict.json")
                let helgaLog = evidenceURL.appendingPathComponent("helga-run.log")
                if fm.fileExists(atPath: helgaJSON.path) || fm.fileExists(atPath: helgaLog.path) {
                    records.append(helgaRecord(project: project, taskName: taskName, title: title, taskURL: taskURL, jsonURL: helgaJSON, logURL: helgaLog))
                }
            }
        }
        return records
    }

    static var hosakaRunsRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hosaka/runs").path
    }

    /// Hosaka vNext run records: <runsRoot>/<project>/<run-id>/ with evidence/, requirements.md and events.ndjson.
    static func hosakaRunRecords(runsRoot: String) -> [JobRecord] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: runsRoot, isDirectory: true)
        guard let projectURLs = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { return [] }
        var records: [JobRecord] = []
        for projectURL in projectURLs where isDirectory(projectURL) {
            let dirName = projectURL.lastPathComponent
            let project = dirName.prefix(1).uppercased() + dirName.dropFirst()
            guard let runURLs = try? fm.contentsOfDirectory(at: projectURL, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { continue }
            for runURL in runURLs where isDirectory(runURL) {
                let runID = runURL.lastPathComponent
                let requirements = try? String(contentsOf: runURL.appendingPathComponent("requirements.md"), encoding: .utf8)
                let heading = requirements.flatMap(markdownTitle) ?? runID
                let title = "\(project): \(heading)"
                let evidenceURL = runURL.appendingPathComponent("evidence", isDirectory: true)
                let reviewJSON = evidenceURL.appendingPathComponent("code-review-result.json")
                let reviewSummary = evidenceURL.appendingPathComponent("review-summary.md")
                if fm.fileExists(atPath: reviewJSON.path) || fm.fileExists(atPath: reviewSummary.path) {
                    records.append(reviewRecord(project: project, taskName: runID, title: title, taskURL: runURL,
                                                jsonURL: reviewJSON, summaryURL: reviewSummary))
                }
                let helgaJSON = evidenceURL.appendingPathComponent("helga-verdict.json")
                let helgaLog = evidenceURL.appendingPathComponent("helga-run.log")
                if fm.fileExists(atPath: helgaJSON.path) || fm.fileExists(atPath: helgaLog.path) {
                    records.append(helgaRecord(project: project, taskName: runID, title: title, taskURL: runURL,
                                               jsonURL: helgaJSON, logURL: helgaLog))
                }
            }
        }
        return records
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// When the review really ran: a timestamp in the JSON, else the last matching event in events.ndjson, else mtime.
    static func runTimestamp(json: [String: Any]?, taskURL: URL, eventMatch: String, fallback: [URL]) -> Date {
        for key in ["timestamp", "ts", "completed_at", "finished_at", "generated_at"] {
            if let date = isoDate(json?[key]) { return date }
        }
        if let text = try? String(contentsOf: taskURL.appendingPathComponent("events.ndjson"), encoding: .utf8) {
            let hit = text.components(separatedBy: .newlines).last { $0.localizedCaseInsensitiveContains(eventMatch) }
            if let line = hit, let data = line.data(using: .utf8),
               let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let date = isoDate(event["ts"] ?? event["timestamp"]) {
                return date
            }
        }
        return modificationDate(fallback)
    }

    /// model-turns.jsonl as one line per turn, so a looping investigation is visible at a glance.
    static func modelTurnsSummary(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines: [String] = text.components(separatedBy: .newlines).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let turn = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let number = (turn["turn"] as? Int).map(String.init) ?? "?"
            let prompt = (turn["prompt_tokens"] as? Int).map(String.init) ?? "?"
            let completion = (turn["completion_tokens"] as? Int).map(String.init) ?? "?"
            let action = turnAction(turn["response"] as? String ?? "")
            return "turn \(number) · prompt \(prompt) · completion \(completion) · \(action)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func turnAction(_ response: String) -> String {
        if let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"), start < end,
           let data = String(response[start...end]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let action = object["action"] as? String {
            let detail = (object["command"] ?? object["path"] ?? object["verdict"] ?? object["query"]) as? String
            return oneLine(detail.map { "\(action): \($0)" } ?? action, max: 140)
        }
        let first = response.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") } ?? "(empty)"
        return oneLine(first, max: 140)
    }

    static func oneLine(_ text: String, max: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }

    static func reviewRecord(project: String, taskName: String, title: String, taskURL: URL, jsonURL: URL, summaryURL: URL) -> JobRecord {
        let json = jsonObject(jsonURL)
        let verdict = (json?["verdict"] as? String)?.lowercased()
        let status: JobStatus = verdict == "clean" || verdict == "pass" ? .complete : (verdict == nil ? .unknown : .needsReview)
        let agents = json?["agents_dispatched"] as? Int
        let findings = json?["total_findings_raw"] as? Int
        let summary = [
            verdict.map { "Verdict \($0)" },
            agents.map { "\($0) voices" },
            findings.map { "\($0) findings" },
        ].compactMap { $0 }.joined(separator: " · ")
        let summaryText = readText(summaryURL, limit: 14_000)
        let rawFiles = reviewRawFiles(taskURL: taskURL)
        let output = ([summaryText] + rawFiles).filter { !$0.isEmpty }.joined(separator: "\n\n")
        return JobRecord(
            id: "\(project):peer:\(taskName)",
            project: project,
            workflow: .peer,
            status: status,
            title: title,
            model: nil,
            host: nil,
            taskPath: taskURL.path,
            artifactPath: FileManager.default.fileExists(atPath: jsonURL.path) ? jsonURL.path : summaryURL.path,
            summary: summary.isEmpty ? "Peer review evidence" : summary,
            output: output,
            updatedAt: runTimestamp(json: json, taskURL: taskURL, eventMatch: "review", fallback: [jsonURL, summaryURL, taskURL]),
            eventCount: 0
        )
    }

    static func helgaRecord(project: String, taskName: String, title: String, taskURL: URL, jsonURL: URL, logURL: URL) -> JobRecord {
        let json = jsonObject(jsonURL)
        let verdict = (json?["verdict"] as? String)?.lowercased()
        let status: JobStatus
        switch verdict {
        case "pass": status = .complete
        case "reject", "error", "timeout", "parse_error", "unavailable": status = .failed
        case "needs_review": status = .needsReview
        default: status = .unknown
        }
        let reason = json?["reason"] as? String
        let model = json?["model"] as? String
        let turns = json?["turns"] as? Int
        let tokens = json?["total_tokens"] as? Int
        let elapsed = (json?["elapsed_seconds"] as? NSNumber)?.doubleValue
        let summaryParts = [
            reason ?? verdict.map { "Verdict \($0)" } ?? "Helga evidence",
            turns.map { "\($0) turns" },
            tokens.map { "\($0) tokens" },
            elapsed.map { "\(Int($0.rounded()))s" },
        ].compactMap { $0 }
        let turnsURL = jsonURL.deletingLastPathComponent().appendingPathComponent("helga-diagnostics/model-turns.jsonl")
        let turnList = modelTurnsSummary(turnsURL)
        let logTail = readTailText(logURL, limit: 12_000)
        let output = [
            readText(jsonURL, limit: 12_000),
            turnList.map { "Model turns:\n\($0)" } ?? "",
            logTail.isEmpty ? "" : "Tail of helga-run.log:\n\(logTail)",
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return JobRecord(
            id: "\(project):helga:\(taskName)",
            project: project,
            workflow: .helga,
            status: status,
            title: title,
            model: model,
            host: nil,
            taskPath: taskURL.path,
            artifactPath: FileManager.default.fileExists(atPath: jsonURL.path) ? jsonURL.path : logURL.path,
            summary: summaryParts.joined(separator: " · "),
            output: output,
            updatedAt: runTimestamp(json: json, taskURL: taskURL, eventMatch: "helga", fallback: [jsonURL, logURL, taskURL]),
            eventCount: 0
        )
    }

    static func rlArtifactRecords(root: String) -> [JobRecord] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        guard fm.fileExists(atPath: rootURL.path) else { return [] }
        var records: [JobRecord] = []
        records.append(contentsOf: rlStudioResearchRecords(rootURL: rootURL))

        let logsURL = rootURL.appendingPathComponent("QA/logs-run", isDirectory: true)
        if let urls = try? fm.contentsOfDirectory(at: logsURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for url in urls.filter({ ["log", "md", "json"].contains($0.pathExtension.lowercased()) }).sorted(by: newestFirst).prefix(40) {
                records.append(JobRecord(
                    id: "RL:background:logs-run:\(url.lastPathComponent)",
                    project: "RL",
                    workflow: .background,
                    status: url.pathExtension.lowercased() == "json" ? .complete : .unknown,
                    title: url.deletingPathExtension().lastPathComponent,
                    model: nil,
                    host: nil,
                    taskPath: logsURL.path,
                    artifactPath: url.path,
                    summary: "RL background log",
                    output: readText(url, limit: 18_000),
                    updatedAt: modificationDate([url]),
                    eventCount: 0
                ))
            }
        }

        let doneURL = rootURL.appendingPathComponent("Done", isDirectory: true)
        if let appURLs = try? fm.contentsOfDirectory(at: doneURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for appURL in appURLs.sorted(by: newestFirst).prefix(80) {
                guard ((try? appURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) else { continue }
                let backgroundURL = appURL.appendingPathComponent("Background", isDirectory: true)
                guard let urls = try? fm.contentsOfDirectory(at: backgroundURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
                for url in urls.filter({ $0.pathExtension.lowercased() == "md" }).sorted(by: newestFirst).prefix(3) {
                    records.append(JobRecord(
                        id: "RL:background:\(appURL.lastPathComponent):\(url.lastPathComponent)",
                        project: "RL",
                        workflow: .background,
                        status: .complete,
                        title: "\(appURL.lastPathComponent) background",
                        model: nil,
                        host: nil,
                        taskPath: appURL.path,
                        artifactPath: url.path,
                        summary: firstMeaningfulLine(url) ?? "Background research artifact",
                        output: readText(url, limit: 18_000),
                        updatedAt: modificationDate([url]),
                        eventCount: 0
                    ))
                }
            }
        }

        return records
    }

    static func rlStudioResearchRecords(rootURL: URL) -> [JobRecord] {
        let researchURL = rootURL.appendingPathComponent("Studio/static/research", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: researchURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var grouped: [String: [URL]] = [:]
        for url in urls where ["md", "json"].contains(url.pathExtension.lowercased()) {
            guard let base = rlResearchRunBase(url.lastPathComponent) else { continue }
            grouped[base, default: []].append(url)
        }

        return grouped.compactMap { base, groupURLs in
            let sortedURLs = groupURLs.sorted(by: newestFirst)
            guard let primaryURL = primaryResearchURL(base: base, urls: sortedURLs) else { return nil }
            let statusURL = sortedURLs.first { $0.lastPathComponent == "\(base).status.json" }
            let statusJSON = statusURL.flatMap(jsonObject)
            let appName = (statusJSON?["app"] as? String) ?? rlResearchTitle(from: base)
            let statusText = (statusJSON?["status"] as? String)?.lowercased()
            let status = rlJobStatus(from: statusText, outputURL: primaryURL)
            let passes = statusJSON?["passes"] as? [String]
            let summary = [
                statusText.map { "Status \($0)" },
                passes.map { "\($0.count) passes" },
                firstMeaningfulLine(primaryURL),
            ].compactMap { $0 }.joined(separator: " · ")
            let orderedOutputURLs = [statusURL, primaryURL]
                .compactMap { $0 }
                + sortedURLs.filter { url in
                    url != statusURL && url != primaryURL && ["main.md", "technical.md"].contains(where: { url.lastPathComponent.hasSuffix($0) })
                }
            let output = orderedOutputURLs
                .reduce(into: [URL]()) { unique, url in
                    if !unique.contains(url) { unique.append(url) }
                }
                .map { readText($0, limit: 12_000) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")

            return JobRecord(
                id: "RL:background:studio:\(base)",
                project: "RL",
                workflow: .background,
                status: status,
                title: "\(appName) background",
                model: nil,
                host: nil,
                taskPath: researchURL.path,
                artifactPath: primaryURL.path,
                summary: summary.isEmpty ? "Studio background research run" : summary,
                output: output,
                updatedAt: modificationDate(sortedURLs),
                eventCount: 0
            )
        }
    }

    static func primaryResearchURL(base: String, urls: [URL]) -> URL? {
        urls.first { $0.lastPathComponent == "\(base).md" }
            ?? urls.first { $0.lastPathComponent == "\(base).main.md" }
            ?? urls.first { $0.pathExtension.lowercased() == "md" }
            ?? urls.first { $0.lastPathComponent == "\(base).status.json" }
    }

    static func rlResearchRunBase(_ filename: String) -> String? {
        if filename.hasSuffix(".status.json") {
            return String(filename.dropLast(".status.json".count))
        }
        guard filename.hasSuffix(".md") else { return nil }
        var base = String(filename.dropLast(".md".count))
        for suffix in [".main", ".technical"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        return base.contains(".") ? base : nil
    }

    static func rlResearchTitle(from base: String) -> String {
        let slug = base.split(separator: ".").first.map(String.init) ?? base
        return slug
            .split(separator: "-")
            .map { word in
                let text = String(word)
                switch text.lowercased() {
                case "api": return "API"
                case "pi": return "PI"
                case "rl": return "RL"
                default: return text.capitalized
                }
            }
            .joined(separator: " ")
    }

    static func rlJobStatus(from status: String?, outputURL: URL) -> JobStatus {
        switch status {
        case "complete", "completed", "done", "success":
            return .complete
        case "running", "active", "started":
            return .running
        case "failed", "failure", "error", "timeout":
            return .failed
        case "needs_review":
            return .needsReview
        default:
            return outputURL.pathExtension.lowercased() == "json" ? .unknown : .complete
        }
    }

    static func taskTitle(taskURL: URL) -> String? {
        for name in ["task.yaml", "technical.yaml", "spec.md", "SPEC.md"] {
            let url = taskURL.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let title = yamlTitle(from: text) ?? markdownTitle(from: text) {
                return limit(title, characters: 90).replacingOccurrences(of: "\n...truncated...", with: "...")
            }
        }
        return nil
    }

    static func yamlTitle(from text: String) -> String? {
        for line in text.components(separatedBy: .newlines).prefix(80) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("title:") else { continue }
            return trimmed.dropFirst(6).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return nil
    }

    static func markdownTitle(from text: String) -> String? {
        for line in text.components(separatedBy: .newlines).prefix(80) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#") else { continue }
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    static func reviewRawFiles(taskURL: URL) -> [String] {
        let reviewURL = taskURL.appendingPathComponent("evidence/review", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: reviewURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls
            .filter { $0.lastPathComponent.hasSuffix("-raw.md") }
            .sorted(by: newestFirst)
            .prefix(6)
            .map { readText($0, limit: 8_000) }
    }

    static func jsonObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func readText(_ url: URL, limit characters: Int) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return limit(text.trimmingCharacters(in: .whitespacesAndNewlines), characters: characters)
    }

    static func readTailText(_ url: URL, limit characters: Int) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > characters else { return trimmed }
        return "...truncated...\n" + String(trimmed.suffix(characters))
    }

    static func firstMeaningfulLine(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: .newlines).prefix(80) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 8 {
                return limit(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), characters: 140)
            }
        }
        return nil
    }

    static func newestFirst(_ lhs: URL, _ rhs: URL) -> Bool {
        modificationDate([lhs]) > modificationDate([rhs])
    }

    static func modificationDate(_ urls: [URL]) -> Date {
        urls.compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }.max() ?? .distantPast
    }

}

