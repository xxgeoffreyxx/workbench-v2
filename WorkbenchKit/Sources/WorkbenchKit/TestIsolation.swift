import Foundation

/// UI-test isolation. The UI tests launch the app with `-WorkbenchUITesting`; the app then keeps its Core Data
/// store in memory and its own settings in a separate defaults suite, so tests never touch real data.
/// A launch without the flag uses the normal store and UserDefaults.standard.
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
}
