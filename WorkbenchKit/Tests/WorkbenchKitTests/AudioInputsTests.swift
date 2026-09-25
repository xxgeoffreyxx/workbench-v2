import XCTest
@testable import WorkbenchKit

final class AudioInputsTests: XCTestCase {
    let builtIn = AudioInput(id: 1, uid: "builtin", name: "MacBook Pro Microphone", isBuiltIn: true, isVirtual: false)
    let camera = AudioInput(id: 2, uid: "cam", name: "GDM 4K Camera Microphone", isBuiltIn: false, isVirtual: false)
    let zoom = AudioInput(id: 3, uid: "zoom", name: "ZoomAudioDevice", isBuiltIn: false, isVirtual: true)

    func testLidClosedSkipsBuiltInMic() {
        let pick = AudioInputs.resolve(preferredUID: nil, inputs: [builtIn, zoom, camera], defaultID: 1, lidClosed: true)
        XCTAssertEqual(pick?.uid, "cam")
    }

    func testLidOpenUsesDefault() {
        XCTAssertEqual(AudioInputs.resolve(preferredUID: nil, inputs: [builtIn, camera], defaultID: 1, lidClosed: false)?.uid, "builtin")
    }

    func testVirtualDefaultIsSkipped() {
        XCTAssertEqual(AudioInputs.resolve(preferredUID: nil, inputs: [zoom, camera], defaultID: 3, lidClosed: false)?.uid, "cam")
    }

    func testSavedChoiceWinsWhileConnected() {
        XCTAssertEqual(AudioInputs.resolve(preferredUID: "builtin", inputs: [builtIn, camera], defaultID: 2, lidClosed: true)?.uid, "builtin")
        XCTAssertEqual(AudioInputs.resolve(preferredUID: "gone", inputs: [builtIn, camera], defaultID: 2, lidClosed: true)?.uid, "cam")
    }

    /// Real devices on this Mac. Skipped unless WB_LIVE=1.
    func testLiveDevices() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WB_LIVE"] == "1")
        for input in AudioInputs.all() { print("LIVE input: \(input.name) builtIn=\(input.isBuiltIn) virtual=\(input.isVirtual)") }
        print("LIVE lidClosed=\(AudioInputs.isLidClosed()) chosen=\(AudioInputs.resolve(preferredUID: nil)?.name ?? "none")")
    }
}
