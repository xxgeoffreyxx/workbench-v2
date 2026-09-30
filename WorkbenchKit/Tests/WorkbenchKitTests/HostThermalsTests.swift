import XCTest
@testable import WorkbenchKit

final class HostThermalsTests: XCTestCase {
    let line = #"{"ts": "2026-09-30T05:48:44-0700", "pressure": "Heavy", "gpu_mhz": 1110, "gpu_busy_pct": 97.5, "gpu_w": 31.2, "gpu_c": 64.5, "die_c": 63.9, "soc_c": 62.4, "hottest_c": 65.7}"#

    func testParsesThermalSampleLine() throws {
        let t = try XCTUnwrap(HostThermals.parse(host: "m1max", output: "some ssh banner\n" + line + "\n"))
        XCTAssertEqual(t.host, "m1max")
        XCTAssertEqual(t.gpuC, 64.5)
        XCTAssertEqual(t.cpuC, 63.9, "die_c is the CPU/die figure")
        XCTAssertEqual(t.gpuMHz, 1110)
        XCTAssertEqual(t.pressure, "Heavy")
        XCTAssertEqual(t.sampledAt, ISO8601DateFormatter().date(from: "2026-09-30T12:48:44Z"))
    }

    func testAcceptsServerFieldNames() throws {
        let t = try XCTUnwrap(HostThermals.parse(host: "h", output: #"{"cpu_c": 50.2, "gpu_c": 40, "gpu_mhz": 389.6}"#))
        XCTAssertEqual(t.cpuC, 50.2)
        XCTAssertEqual(t.gpuMHz, 390)
    }

    func testRejectsGarbage() {
        XCTAssertNil(HostThermals.parse(host: "h", output: "ssh: connect to host m1max port 22: Operation timed out"))
        XCTAssertNil(HostThermals.parse(host: "h", output: #"{"unrelated": 1}"#))
    }

    func testSummaryText() throws {
        let t = try XCTUnwrap(HostThermals.parse(host: "m1max", output: line))
        XCTAssertEqual(t.summary, "GPU 65°C · CPU 64°C · 1110 MHz · Heavy")
    }
}

final class ThermalLevelTests: XCTestCase {
    func testTemperatureThresholds() {
        XCTAssertEqual(ThermalLevel.temperature(79.9), .normal)
        XCTAssertEqual(ThermalLevel.temperature(80), .elevated)
        XCTAssertEqual(ThermalLevel.temperature(89.9), .elevated)
        XCTAssertEqual(ThermalLevel.temperature(90), .high)
    }

    func testGPUClockOnlyJudgedUnderLoad() {
        XCTAssertEqual(ThermalLevel.gpuClock(mhz: 389, busyPct: 5), .normal, "a low clock at idle is not throttling")
        XCTAssertEqual(ThermalLevel.gpuClock(mhz: 1279, busyPct: 97), .normal)
        XCTAssertEqual(ThermalLevel.gpuClock(mhz: 1100, busyPct: 97), .elevated)
        XCTAssertEqual(ThermalLevel.gpuClock(mhz: 920, busyPct: 97), .high)
        XCTAssertEqual(ThermalLevel.gpuClock(mhz: 920, busyPct: nil), .normal)
    }

    func testPressure() {
        XCTAssertEqual(ThermalLevel.pressure("Nominal"), .normal)
        XCTAssertEqual(ThermalLevel.pressure("Moderate"), .elevated)
        XCTAssertEqual(ThermalLevel.pressure("Heavy"), .high)
    }
}
