import XCTest
@testable import WorkbenchKit

final class ImportTests: XCTestCase {
    let fixture = """
    [{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","title":"Hello","model":"http://127.0.0.1:8110/v1#ornith",
      "workspacePath":"/tmp/ws","activityLog":["a"],"status":"idle",
      "createdAt":"2026-06-01T10:00:00Z","updatedAt":"2026-06-01T10:05:00Z",
      "messages":[
        {"id":"7F9619FF-8B86-D011-B42D-00CF4FC964FF","role":"user","content":"hi","createdAt":"2026-06-01T10:00:00Z"},
        {"id":"8F9619FF-8B86-D011-B42D-00CF4FC964FF","role":"assistant","content":"hey","reasoning":"think","createdAt":"2026-06-01T10:01:00Z"}]},
     {"id":"9F9619FF-8B86-D011-B42D-00CF4FC964FF","title":"Old","model":"m","activityLog":[],"status":"idle",
      "createdAt":"2026-05-01T10:00:00Z","updatedAt":"2026-05-01T10:00:00Z","messages":[],"archived":true}]
    """

    func testDecodesFixture() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("threads-\(UUID()).json")
        try Data(fixture.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let threads = try BenchImport.loadThreads(from: url)
        XCTAssertEqual(threads.count, 2)
        XCTAssertEqual(threads[0].title, "Hello")
        XCTAssertEqual(threads[0].workspacePath, "/tmp/ws")
        XCTAssertFalse(threads[0].archived)
        XCTAssertEqual(threads[0].messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(threads[0].messages[1].reasoning, "think")
        XCTAssertNil(threads[0].messages[0].reasoning)
        XCTAssertTrue(threads[1].archived)
        XCTAssertNil(threads[1].workspacePath)
    }
}
