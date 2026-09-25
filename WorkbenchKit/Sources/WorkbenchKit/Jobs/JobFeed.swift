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
    public static func load() -> [JobRecord] { loadJobRecords() }

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
        var recordsByID: [String: JobRecord] = [:]
        for record in artifactJobRecords() {
            recordsByID[record.id] = record
        }
        for event in jobEvents() {
            let existing = recordsByID[event.jobID]
            let eventOutput = event.output ?? eventArtifactOutput(for: event)
            recordsByID[event.jobID] = JobRecord(
                id: event.jobID,
                project: event.project,
                workflow: event.workflow,
                status: event.status,
                title: event.title,
                model: event.model ?? existing?.model,
                host: event.host ?? existing?.host,
                taskPath: event.taskPath ?? existing?.taskPath,
                artifactPath: event.artifactPath ?? existing?.artifactPath,
                summary: event.summary ?? existing?.summary ?? event.status.rawValue,
                output: eventOutput ?? existing?.output ?? "",
                updatedAt: max(event.timestamp, existing?.updatedAt ?? .distantPast),
                eventCount: (existing?.eventCount ?? 0) + 1
            )
        }
        return recordsByID.values.sorted {
            let lhsRunning = $0.status == .running
            let rhsRunning = $1.status == .running
            if lhsRunning != rhsRunning { return lhsRunning && !rhsRunning }
            let lhsProject = projectSortRank($0.project)
            let rhsProject = projectSortRank($1.project)
            if lhsProject != rhsProject { return lhsProject < rhsProject }
            let lhsWorkflow = workflowSortRank($0.workflow)
            let rhsWorkflow = workflowSortRank($1.workflow)
            if lhsWorkflow != rhsWorkflow { return lhsWorkflow < rhsWorkflow }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    static func projectSortRank(_ project: String) -> Int {
        switch project.lowercased() {
        case "scout": return 0
        case "thriveos": return 1
        case "rl": return 2
        default: return 10
        }
    }

    static func workflowSortRank(_ workflow: JobWorkflow) -> Int {
        switch workflow {
        case .background: return 0
        case .helga: return 1
        case .peer: return 2
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

            for taskURL in taskURLs.prefix(240) {
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
            updatedAt: modificationDate([jsonURL, summaryURL, taskURL]),
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
        let output = [
            readText(jsonURL, limit: 12_000),
            readText(logURL, limit: 12_000),
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
            summary: reason ?? verdict.map { "Verdict \($0)" } ?? "Helga evidence",
            output: output,
            updatedAt: modificationDate([jsonURL, logURL, taskURL]),
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

