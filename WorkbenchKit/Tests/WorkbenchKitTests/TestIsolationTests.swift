import XCTest
@testable import WorkbenchKit

final class TestIsolationTests: XCTestCase {
    func testFlagDetected() {
        XCTAssertTrue(TestIsolation.isUITesting(arguments: ["/App", "-WorkbenchUITesting"]))
        XCTAssertTrue(TestIsolation.isUITesting(arguments: ["/App", "-X", "1", "-WorkbenchUITesting"]))
    }

    func testProductionLaunchIsNotUITesting() {
        XCTAssertFalse(TestIsolation.isUITesting(arguments: ["/App"]))
        XCTAssertFalse(TestIsolation.isUITesting(arguments: ["/App", "-WorkbenchTestProjectFolder", "/tmp/x"]))
        XCTAssertFalse(TestIsolation.isUITesting(arguments: ["/App", "WorkbenchUITesting"]))
    }

    func testDefaultsAreStandardInProduction() {
        XCTAssertTrue(TestIsolation.defaults(arguments: ["/App"]) === UserDefaults.standard)
    }

    func testDefaultsAreTheTestSuiteWhenUITesting() {
        let d = TestIsolation.defaults(arguments: ["/App", "-WorkbenchUITesting"])
        XCTAssertFalse(d === UserDefaults.standard)
        d.set("x", forKey: "TestIsolationTests.probe")
        XCTAssertNil(UserDefaults.standard.object(forKey: "TestIsolationTests.probe"))
        XCTAssertEqual(UserDefaults(suiteName: TestIsolation.defaultsSuiteName)?.string(forKey: "TestIsolationTests.probe"), "x")
        d.removeObject(forKey: "TestIsolationTests.probe")
    }

    func testPersistentFileIsNilWhenUITestingAndUnchangedInProduction() {
        let url = URL(fileURLWithPath: "/tmp/support/project-folders.json")
        XCTAssertNil(TestIsolation.persistentFile(url, arguments: ["/App", "-WorkbenchUITesting"]))
        XCTAssertEqual(TestIsolation.persistentFile(url, arguments: ["/App"]), url)
    }
}
