import XCTest
@testable import WorkbenchKit

final class SmokeTests: XCTestCase {
    func testRouterURL() { XCTAssertEqual(Workbench.routerBaseURL.path, "/v1") }
}
