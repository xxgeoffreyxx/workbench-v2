import XCTest
@testable import WorkbenchKit

final class RouterTests: XCTestCase {
    func testReasoningSplit() {
        let r = ReasoningExtractor.split("<think> plan </think>\nAnswer")
        XCTAssertEqual(r.reasoning, "plan")
        XCTAssertEqual(r.content, "Answer")
        let plain = ReasoningExtractor.split("no think here")
        XCTAssertNil(plain.reasoning)
        XCTAssertEqual(plain.content, "no think here")
        let empty = ReasoningExtractor.split("<THINK></THINK>hi")
        XCTAssertNil(empty.reasoning)
        XCTAssertEqual(empty.content, "hi")
    }

    func testCanonicalModelIDs() {
        XCTAssertEqual(ModelCatalog.canonicalWorkbenchModelID(for: "http://x/v1#ornith"), "ornith")
        XCTAssertEqual(ModelCatalog.canonicalWorkbenchModelID(for: "hosaka-helga"), "ornith")
        XCTAssertEqual(ModelCatalog.canonicalWorkbenchModelID(for: "qwen-cloud"), "qwen-plus")
        XCTAssertEqual(ModelCatalog.canonicalWorkbenchModelID(for: "qwen-flash"), "qwen-flash")
        XCTAssertEqual(ModelCatalog.canonicalWorkbenchModelID(for: "helper", backend: "mlx/Ornith-8bit"), "ornith")
        XCTAssertNil(ModelCatalog.canonicalWorkbenchModelID(for: "qwen30", backend: "x"))
        XCTAssertNil(ModelCatalog.canonicalWorkbenchModelID(for: "/Users/m1max/dorsett-13-mlx-8bit", backend: "x"))
        XCTAssertEqual(ModelCatalog.canonicalWorkbenchModelID(for: "NewModel", backend: "b"), "newmodel")
        XCTAssertNil(ModelCatalog.canonicalWorkbenchModelID(for: "newmodel"))
        XCTAssertEqual(ModelCatalog.displayTitle(for: "ornith"), "Ornith (Helga)")
    }

    func testResidentModelsFromHealth() throws {
        let json = #"{"ok":true,"models":{"hosaka-helga":{"host":"m1max","ready":false},"ornith":{"host":"m1max","ready":true},"qwen30":{"ready":true}}}"#
        let health = try JSONDecoder().decode(RouterHealthResponse.self, from: Data(json.utf8))
        let resident = ModelCatalog.residentModels(from: health.models)
        XCTAssertEqual(resident, [ResidentModel(canonical: "ornith", title: "Ornith (Helga)", host: "m1max", ready: true)])
        XCTAssertEqual(ModelCatalog.readinessByCanonicalModel(from: health.models), ["ornith": true])
    }

    func testDorsettSummary() {
        let parsed = Dorsett.summary(from: #"{"summary":"Good fit {really}","score":8} trailing"#)
        XCTAssertEqual(parsed?.summary, "Good fit {really}")
        XCTAssertNil(Dorsett.summary(from: #"{"score":8}"#))
        XCTAssertEqual(Dorsett.summary(from: #"{"summary":"","content":"alt"}"#)?.summary, "alt")
        XCTAssertEqual(Dorsett.fragmentValue(from: #"{"summary": "line\nnext", "summary": "#), "line\nnext")
        XCTAssertTrue(RouterModel.dorsett(ready: true).allSatisfy(\.isDorsett))
    }
}
