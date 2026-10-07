import Foundation

public struct ShellResult: Sendable {
    public let exitCode: Int32
    public let output: String
    public let timedOut: Bool
    public var successOutput: String? { exitCode == 0 ? output : nil }
}

public enum Shell {
    static var toolPATH: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }

    /// Synchronous run used by context collection (git, find).
    public static func runSync(_ executable: String, _ arguments: [String], cwd: String? = nil) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ShellResult(exitCode: process.terminationStatus, output: String(decoding: data, as: UTF8.self), timedOut: false)
        } catch {
            return ShellResult(exitCode: 127, output: error.localizedDescription, timedOut: false)
        }
    }

    /// Async run with a timeout; output is merged stdout+stderr.
    public static func run(_ executable: String, arguments: [String], cwd: String? = nil, timeoutSeconds: Double) async -> ShellResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = toolPATH
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch {
                continuation.resume(returning: ShellResult(exitCode: 127, output: "\(executable) failed to start: \(error.localizedDescription)", timedOut: false))
                return
            }
            let timedOut = TimeoutFlag()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                if process.isRunning { timedOut.set(); process.terminate() }
            }
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: ShellResult(exitCode: process.terminationStatus,
                                                           output: String(decoding: data, as: UTF8.self),
                                                           timedOut: timedOut.value))
            }
        }
    }

    public static func limit(_ text: String, characters: Int) -> String {
        text.count <= characters ? text : String(text.prefix(characters)) + "\n...truncated..."
    }

    /// Keeps the tail (where errors usually are) when output is too long.
    public static func limitTail(_ text: String, characters: Int) -> String {
        text.count <= characters ? text : "...(\(text.count - characters) earlier characters omitted)...\n" + String(text.suffix(characters))
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
