import XCTest
@testable import WorkbenchKit

final class SpeechTests: XCTestCase {
    func testFencedCodeIsOmitted() {
        let md = "Here:\n```swift\nlet x = 1\n```\nDone."
        XCTAssertEqual(SpeechReader.plainText(fromMarkdown: md), "Here:\ncode block omitted.\nDone.")
    }

    func testInlineMarkupAndLinks() {
        let md = "# Title\n- **Bold** and *italic* with `code` see [the docs](https://x.y)."
        XCTAssertEqual(SpeechReader.plainText(fromMarkdown: md), "Title\nBold and italic with code see the docs.")
    }

    func testSnakeCaseSurvives() {
        XCTAssertEqual(SpeechReader.plainText(fromMarkdown: "call my_func_name now"), "call my_func_name now")
    }
}
