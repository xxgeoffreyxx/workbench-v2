import Foundation

/// UI-test isolation. The UI tests launch the app with `-WorkbenchUITesting`. Under the flag the app:
/// - keeps its Core Data store in memory,
/// - writes its own settings to the `WorkbenchUITests` defaults suite,
/// - keeps project folders (`project-folders.json`) in memory only,
/// - skips the keychain migration at startup.
/// Other users of UserDefaults.standard and the keychain are NOT redirected; for those the UI tests rely on
/// running under a separate test bundle ID. A launch without the flag uses the normal store, files and
/// UserDefaults.standard.
public enum TestIsolation {
    public static let flag = "-WorkbenchUITesting"
    public static let defaultsSuiteName = "WorkbenchUITests"

    public static func isUITesting(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.dropFirst().contains(flag)
    }

    /// The defaults the app should write its own settings to.
    public static func defaults(arguments: [String] = ProcessInfo.processInfo.arguments) -> UserDefaults {
        guard isUITesting(arguments: arguments), let suite = UserDefaults(suiteName: defaultsSuiteName) else {
            return .standard
        }
        return suite
    }

    /// The file to persist to, or nil when UI testing (keep the data in memory only).
    public static func persistentFile(_ url: URL, arguments: [String] = ProcessInfo.processInfo.arguments) -> URL? {
        isUITesting(arguments: arguments) ? nil : url
    }
}
