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


/// A sampler process the test controls: it never exits on its own unless told to.
private final class FakeSamplerProcess: SamplerProcess, @unchecked Sendable {
    enum Behavior { case hang, fail, succeed(String) }
    let behavior: Behavior
    private let lock = NSLock()
    private var onExit: (@Sendable (String, Bool) -> Void)?
    private(set) var terminated = false
    init(_ behavior: Behavior) { self.behavior = behavior }

    func start(onExit: @escaping @Sendable (String, Bool) -> Void) throws {
        switch behavior {
        case .hang: lock.withLock { self.onExit = onExit }
        case .fail: onExit("", false)
        case .succeed(let output): onExit(output, true)
        }
    }

    func terminate() {
        let exit = lock.withLock { () -> (@Sendable (String, Bool) -> Void)? in
            terminated = true
            defer { onExit = nil }
            return onExit
        }
        exit?("", false)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private final class Launches: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FakeSamplerProcess] = []
    var all: [FakeSamplerProcess] { lock.withLock { items } }
    func add(_ p: FakeSamplerProcess) { lock.withLock { items.append(p) } }
}

final class ThermalSamplerTests: XCTestCase {
    let line = #"{"gpu_c": 60, "die_c": 55, "gpu_mhz": 1200, "pressure": "Nominal"}"#

    private func sampler(_ behaviors: [FakeSamplerProcess.Behavior], timeout: TimeInterval = 5, clock: Clock,
                         launches: Launches) -> ThermalSampler {
        var remaining = behaviors
        let lock = NSLock()
        return ThermalSampler(timeout: timeout, backoffBase: 100, backoffMax: 1_000, now: { clock.now }, makeProcess: { _ in
            let behavior = lock.withLock { remaining.isEmpty ? FakeSamplerProcess.Behavior.hang : remaining.removeFirst() }
            let process = FakeSamplerProcess(behavior)
            launches.add(process)
            return process
        })
    }

    func testNoSecondLaunchWhileOneIsInFlight() {
        let clock = Clock(), launches = Launches()
        let s = sampler([.hang], clock: clock, launches: launches)
        XCTAssertTrue(s.tick(host: "m1max") { _ in })
        XCTAssertFalse(s.tick(host: "m1max") { _ in }, "a tick while a sample is running is skipped")
        XCTAssertEqual(launches.all.count, 1)
    }

    func testHungSampleIsTerminatedAfterDeadline() {
        let clock = Clock(), launches = Launches()
        let s = sampler([.hang, .succeed(line)], timeout: 0.05, clock: clock, launches: launches)
        let done = expectation(description: "completion")
        XCTAssertTrue(s.tick(host: "m1max") { result in XCTAssertNil(result); done.fulfill() })
        wait(for: [done], timeout: 2)
        XCTAssertTrue(launches.all[0].terminated, "the hung process is killed at the deadline")
        XCTAssertFalse(s.isInFlight(host: "m1max"))
    }

    func testBackoffAfterFailureThenRecovers() {
        let clock = Clock(), launches = Launches()
        let s = sampler([.fail, .fail, .succeed(line), .succeed(line)], clock: clock, launches: launches)
        XCTAssertTrue(s.tick(host: "m1max") { XCTAssertNil($0) })
        XCTAssertFalse(s.tick(host: "m1max") { _ in }, "backing off right after a failure")
        clock.advance(101)
        XCTAssertTrue(s.tick(host: "m1max") { XCTAssertNil($0) })
        clock.advance(101)
        XCTAssertFalse(s.tick(host: "m1max") { _ in }, "second failure doubles the wait to 200s")
        clock.advance(100)
        var got: HostThermals?
        XCTAssertTrue(s.tick(host: "m1max") { got = $0 })
        XCTAssertEqual(got?.gpuC, 60)
        XCTAssertTrue(s.tick(host: "m1max") { _ in }, "success clears the backoff")
        XCTAssertEqual(launches.all.count, 4)
    }

    // MARK: - Real-process drain

    private func runSampler(_ script: String, timeout: TimeInterval) -> (output: String?, elapsed: TimeInterval) {
        let sampler = ThermalSampler(timeout: timeout, makeProcess: { _ in
            SSHSamplerProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        })
        let done = expectation(description: "completion")
        let box = OutputBox()
        let started = Date()
        sampler.tick(host: "local") { result in
            box.value = result.map { _ in "parsed" }
            done.fulfill()
        }
        wait(for: [done], timeout: timeout + 10)
        return (box.value, Date().timeIntervalSince(started))
    }

    func testLargeOutputDoesNotStallTheProcess() throws {
        let done = expectation(description: "exit")
        let box = OutputBox()
        let p = SSHSamplerProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                                  arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' x; echo; echo '\(line)'"])
        try p.start { output, success in
            box.value = success ? output : nil
            done.fulfill()
        }
        let result = XCTWaiter().wait(for: [done], timeout: 5)
        if result != .completed { p.terminate() }
        XCTAssertEqual(result, .completed, "a >64KB writer must not block on a full pipe")
        let output = try XCTUnwrap(box.value)
        XCTAssertGreaterThan(output.utf8.count, 300_000)
        XCTAssertNotNil(HostThermals.parse(host: "local", output: output))
    }

    func testLargeOutputSampleSucceedsWithinDeadline() {
        let r = runSampler("head -c 300000 /dev/zero | tr '\\0' x; echo; echo '\(line)'", timeout: 5)
        XCTAssertEqual(r.output, "parsed")
        XCTAssertLessThan(r.elapsed, 5)
    }

    func testRetainedOutputIsCapped() throws {
        let done = expectation(description: "exit")
        let box = OutputBox()
        let p = SSHSamplerProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                                  arguments: ["-c", "head -c 3000000 /dev/zero | tr '\\0' x; echo done"])
        try p.start { output, success in
            box.value = success ? output : nil
            done.fulfill()
        }
        let result = XCTWaiter().wait(for: [done], timeout: 10)
        if result != .completed { p.terminate() }
        XCTAssertEqual(result, .completed)
        XCTAssertLessThanOrEqual(try XCTUnwrap(box.value).utf8.count, SSHSamplerProcess.maxRetainedBytes)
    }

    func testHungProcessIsTerminatedAtDeadline() {
        let r = runSampler("sleep 30", timeout: 0.5)
        XCTAssertNil(r.output)
        XCTAssertLessThan(r.elapsed, 3, "failure must be reported promptly at the deadline")
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
