import Foundation

/// Shared locations and constants for Workbench.
public enum Workbench {
    public static let routerBaseURL = URL(string: ProcessInfo.processInfo.environment["WORKBENCH_ROUTER_URL"] ?? "http://127.0.0.1:8110/v1")!

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Workbench", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
