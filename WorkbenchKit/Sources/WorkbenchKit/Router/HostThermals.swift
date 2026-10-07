import Foundation

/// GPU/CPU temperature and GPU clock for a model host, read with the Local Trials thermal sampler
/// (scout bench/trial-runner/m1max/thermal-sample.py, installed on the host at ~/bakeoff/thermal-sample.py).
/// It prints one JSON line: {"ts", "pressure", "gpu_mhz", "gpu_busy_pct", "gpu_w", "gpu_c", "die_c", "soc_c", "hottest_c"}.
public struct HostThermals: Hashable, Sendable {
    public let host: String
    public let gpuC: Double?
    public let cpuC: Double?
    public let gpuMHz: Int?
    public let pressure: String?
    public let gpuBusyPct: Double?
    public let sampledAt: Date

    /// Hosts with the sampler installed. Only m1max has it today.
    public static let hosts = ["m1max"]
    /// Each read is an ssh round trip that runs powermetrics for about a second, so poll sparingly.
    public static let pollInterval: TimeInterval = 150

    public var summary: String {
        [
            gpuC.map { "GPU \(Int($0.rounded()))°C" },
            cpuC.map { "CPU \(Int($0.rounded()))°C" },
            gpuMHz.map { "\($0) MHz" },
            pressure,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    public static func parse(host: String, output: String, now: Date = Date()) -> HostThermals? {
        for line in output.components(separatedBy: .newlines).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            func number(_ key: String) -> Double? { (json[key] as? NSNumber)?.doubleValue }
            let gpu = number("gpu_c")
            let cpu = number("die_c") ?? number("cpu_c")
            let mhz = number("gpu_mhz").map { Int($0.rounded()) }
            guard gpu != nil || cpu != nil || mhz != nil else { continue }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withFullTime, .withTimeZone]
            let ts = (json["ts"] as? String).flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
            return HostThermals(host: host, gpuC: gpu, cpuC: cpu, gpuMHz: mhz, pressure: json["pressure"] as? String,
                                gpuBusyPct: number("gpu_busy_pct"), sampledAt: ts ?? now)
        }
        return nil
    }

}

/// One run of the thermal sampler. `start` reports the output and whether it exited cleanly, exactly once.
public protocol SamplerProcess: AnyObject, Sendable {
    func start(onExit: @escaping @Sendable (_ output: String, _ success: Bool) -> Void) throws
    func terminate()
}

/// The real sampler: `ssh <host> python3 ~/bakeoff/thermal-sample.py`.
public final class SSHSamplerProcess: SamplerProcess, @unchecked Sendable {
    private let process = Process()

    public static let maxRetainedBytes = 1 << 20

    public convenience init(host: String) {
        self.init(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                  arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", host,
                              "/usr/bin/python3 ~/bakeoff/thermal-sample.py"])
    }

    public init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
    }

    public func start(onExit: @escaping @Sendable (String, Bool) -> Void) throws {
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        let done = DispatchGroup()
        done.enter() // stdout reaches EOF (or the reader is stopped)
        done.enter() // the process exits
        // These closures hold self strongly on purpose: the object must outlive its reader. The cycle is
        // broken when the reader stops (EOF, or terminate's grace period), which clears both closures.
        readerDone = {
            let first: Bool = self.lock.withLock {
                guard !self.readerStopped else { return false }
                self.readerStopped = true
                self.readerDone = nil
                return true
            }
            guard first else { return }
            reader.readabilityHandler = nil
            done.leave()
        }
        // Drain while the process runs: a child that writes more than the pipe buffer would otherwise block
        // on write and never exit. Only the last maxRetainedBytes are kept (the reading is the last line).
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { self.stopReader(); return }
            self.lock.withLock {
                self.output.append(chunk)
                if self.output.count > Self.maxRetainedBytes {
                    self.output.removeFirst(self.output.count - Self.maxRetainedBytes)
                }
            }
        }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in done.leave() }
        done.notify(queue: .global()) {
            // One snapshot under the lock: terminate() writes wasTerminated under the same lock.
            let (data, success): (Data, Bool) = self.lock.withLock {
                (self.output, !self.launchFailed && !self.wasTerminated && self.process.terminationStatus == 0)
            }
            onExit(String(decoding: data, as: UTF8.self), success)
        }
        do {
            try process.run()
        } catch {
            // The process never started, so its exit leave never comes: balance it here so notify reports the
            // failure once, and drop the handlers so nothing keeps self alive.
            lock.withLock { launchFailed = true }
            process.terminationHandler = nil
            stopReader()
            done.leave()
            throw error
        }
    }

    public func terminate() {
        lock.withLock { wasTerminated = true }
        if process.isRunning { process.terminate() }
        let pid = process.processIdentifier
        // ssh normally exits on SIGTERM; make sure a wedged one cannot linger, then stop the reader in case a
        // grandchild still holds stdout open.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
            self.stopReader()
        }
    }

    private func stopReader() {
        let stop = lock.withLock { readerDone }
        stop?()
    }

    private let lock = NSLock()
    private var output = Data()
    private var readerStopped = false
    private var wasTerminated = false
    private var launchFailed = false
    private var readerDone: (@Sendable () -> Void)?
}

/// Polls hosts with at most one sample in flight per host, a hard deadline per sample (the process is killed when
/// it passes), and exponential backoff after failures, so a hung powermetrics cannot pile up ssh processes.
public final class ThermalSampler: @unchecked Sendable {
    private struct HostState {
        var inFlight: SamplerProcess?
        var failures = 0
        var nextAllowed = Date.distantPast
    }

    private let timeout: TimeInterval
    private let backoffBase: TimeInterval
    private let backoffMax: TimeInterval
    private let now: @Sendable () -> Date
    private let makeProcess: @Sendable (String) -> SamplerProcess
    private let lock = NSLock()
    private var state: [String: HostState] = [:]

    public init(timeout: TimeInterval = 30, backoffBase: TimeInterval = HostThermals.pollInterval,
                backoffMax: TimeInterval = 1_800, now: @escaping @Sendable () -> Date = { Date() },
                makeProcess: @escaping @Sendable (String) -> SamplerProcess = { SSHSamplerProcess(host: $0) }) {
        self.timeout = timeout
        self.backoffBase = backoffBase
        self.backoffMax = backoffMax
        self.now = now
        self.makeProcess = makeProcess
    }

    public func isInFlight(host: String) -> Bool { lock.withLock { state[host]?.inFlight != nil } }

    /// Starts a sample unless one is already running for `host` or it is backing off. Returns whether it started.
    /// `completion` gets the reading, or nil on failure or timeout; it runs on whatever thread the process exits on.
    @discardableResult
    public func tick(host: String, completion: @escaping @Sendable (HostThermals?) -> Void) -> Bool {
        let process: SamplerProcess? = lock.withLock {
            var s = state[host] ?? HostState()
            guard s.inFlight == nil, now() >= s.nextAllowed else { return nil }
            let p = makeProcess(host)
            s.inFlight = p
            state[host] = s
            return p
        }
        guard let process else { return false }
        let finish: @Sendable (String, Bool) -> Void = { [weak self] output, success in
            guard let self else { return }
            let result = success ? HostThermals.parse(host: host, output: output, now: self.now()) : nil
            let owned: Bool = self.lock.withLock {
                guard var s = self.state[host], s.inFlight === process else { return false }
                s.inFlight = nil
                if result != nil {
                    s.failures = 0
                    s.nextAllowed = .distantPast
                } else {
                    s.failures += 1
                    let wait = min(self.backoffBase * pow(2, Double(s.failures - 1)), self.backoffMax)
                    s.nextAllowed = self.now().addingTimeInterval(wait)
                }
                self.state[host] = s
                return true
            }
            if owned { completion(result) }
        }
        do {
            try process.start(onExit: finish)
        } catch {
            finish("", false)
            return true
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.isInFlight(host: host),
                  self.lock.withLock({ self.state[host]?.inFlight === process }) else { return }
            process.terminate()
            finish("", false)
        }
        return true
    }
}

/// Green / amber / red for a thermal reading.
/// GPU clock norms come from the Local Trials handover: ~1280 MHz busy when cool, ~615-950 MHz when throttled
/// (Heavy pressure). Pressure: the trial runner requires Nominal before each attempt.
public enum ThermalLevel: Hashable, Sendable {
    case normal, elevated, high

    public static let tempElevatedC = 80.0
    public static let tempHighC = 90.0
    public static let gpuLoadedBusyPct = 50.0
    public static let gpuElevatedBelowMHz = 1200
    public static let gpuThrottledBelowMHz = 1000

    public static func temperature(_ celsius: Double) -> ThermalLevel {
        celsius >= tempHighC ? .high : (celsius >= tempElevatedC ? .elevated : .normal)
    }

    /// A low clock only means throttling while the GPU is busy; at idle it's just idle.
    public static func gpuClock(mhz: Int, busyPct: Double?) -> ThermalLevel {
        guard let busyPct, busyPct >= gpuLoadedBusyPct else { return .normal }
        return mhz < gpuThrottledBelowMHz ? .high : (mhz < gpuElevatedBelowMHz ? .elevated : .normal)
    }

    public static func pressure(_ value: String) -> ThermalLevel {
        switch value.lowercased() {
        case "nominal": return .normal
        case "moderate", "fair": return .elevated
        default: return .high
        }
    }
}

extension HostThermals {
    /// Each value with its level, in display order.
    public var parts: [(text: String, level: ThermalLevel)] {
        var out: [(String, ThermalLevel)] = []
        if let gpuC { out.append(("GPU \(Int(gpuC.rounded()))°C", ThermalLevel.temperature(gpuC))) }
        if let cpuC { out.append(("CPU \(Int(cpuC.rounded()))°C", ThermalLevel.temperature(cpuC))) }
        if let gpuMHz { out.append(("\(gpuMHz) MHz", ThermalLevel.gpuClock(mhz: gpuMHz, busyPct: gpuBusyPct))) }
        if let pressure { out.append((pressure, ThermalLevel.pressure(pressure))) }
        return out
    }
}
