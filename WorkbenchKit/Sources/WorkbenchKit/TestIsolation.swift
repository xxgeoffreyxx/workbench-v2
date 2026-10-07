import Foundation

/// UI-test isolation. The UI tests launch the app with `-WorkbenchUITesting`. Under the flag the app:
/// - keeps its Core Data store in memory,
/// - writes its own settings to the `WorkbenchUITests` defaults suite,
/// - keeps project folders (`project-folders.json`) in memory only,
/// - skips the keychain migration at startup.
/// Other users of UserDefaults.standard and the keychain are NOT redirected; for those the UI tests rely on
/// running under a separate test bundle ID; app preferences and persistence reject flagged launches with
/// any other identity before accessing stores. A launch without the flag uses the normal store, files and
/// UserDefaults.standard.
public enum TestIsolation {
    public static let flag = "-WorkbenchUITesting"
    public static let defaultsSuiteName = "WorkbenchUITests"
    public static let appBundleIdentifier = "me.mccaleb.Workbench.UITesting"

    public static func isLaunchAllowed(arguments: [String], bundleIdentifier: String?) -> Bool {
        !isUITesting(arguments: arguments) || bundleIdentifier == appBundleIdentifier
    }

    /// Reject a test launch before app preferences, persistence or credentials are accessed.
    public static func requireSafeLaunch() {
        guard isLaunchAllowed(arguments: ProcessInfo.processInfo.arguments,
                              bundleIdentifier: Bundle.main.bundleIdentifier) else {
            fatalError("UI tests require WORKBENCH_APP_BUNDLE_IDENTIFIER=\(appBundleIdentifier); refusing the production identity")
        }
    }

    public static func isUITesting(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.dropFirst().contains(flag)
    }

    /// The defaults the app should write its own settings to.
    public static func defaults(arguments: [String] = ProcessInfo.processInfo.arguments) -> UserDefaults {
        requireSafeLaunch()
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
