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

    /// Runs the sampler on `host` over ssh. Blocking; call off the main thread.
    public static func sample(host: String) -> HostThermals? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", host,
                             "/usr/bin/python3 ~/bakeoff/thermal-sample.py"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(host: host, output: String(data: data, encoding: .utf8) ?? "")
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
