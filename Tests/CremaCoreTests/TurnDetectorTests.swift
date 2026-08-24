import XCTest
@testable import CremaCore

final class TurnDetectorTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 2000)

    private func proc(pid: pid_t, cpuNanos: UInt64) -> ScannedProcess {
        ScannedProcess(pid: pid, ppid: 1, name: "claude",
                       cpuNanos: cpuNanos, startTime: start, cwd: "")
    }

    func testCPUBurstMarksWorking() {
        let detector = TurnDetector()
        // First sample establishes a baseline; nothing is "working" yet.
        _ = detector.update(processes: [proc(pid: 1, cpuNanos: 0)], now: start)
        // One full core-second of CPU over one wall second -> working.
        let working = detector.update(
            processes: [proc(pid: 1, cpuNanos: 1_000_000_000)],
            now: start.addingTimeInterval(1)
        )
        XCTAssertTrue(working.contains(1))
    }

    func testFlatCPUMarksWaitingAfterStickyWindow() {
        var config = TurnDetector.Config()
        config.stickySeconds = 8
        let detector = TurnDetector(config: config)

        _ = detector.update(processes: [proc(pid: 2, cpuNanos: 0)], now: start)
        _ = detector.update(processes: [proc(pid: 2, cpuNanos: 1_000_000_000)],
                            now: start.addingTimeInterval(1))
        // No further CPU growth; past the sticky window it should read waiting.
        let working = detector.update(
            processes: [proc(pid: 2, cpuNanos: 1_000_000_000)],
            now: start.addingTimeInterval(20)
        )
        XCTAssertFalse(working.contains(2))
    }

    func testStickyWindowKeepsWorkingBriefly() {
        var config = TurnDetector.Config()
        config.stickySeconds = 8
        let detector = TurnDetector(config: config)

        _ = detector.update(processes: [proc(pid: 3, cpuNanos: 0)], now: start)
        _ = detector.update(processes: [proc(pid: 3, cpuNanos: 1_000_000_000)],
                            now: start.addingTimeInterval(1))
        // Within the sticky window even with no new CPU, still working.
        let working = detector.update(
            processes: [proc(pid: 3, cpuNanos: 1_000_000_000)],
            now: start.addingTimeInterval(4)
        )
        XCTAssertTrue(working.contains(3))
    }

    func testExitedProcessIsForgotten() {
        let detector = TurnDetector()
        _ = detector.update(processes: [proc(pid: 4, cpuNanos: 0)], now: start)
        _ = detector.update(processes: [], now: start.addingTimeInterval(1))
        XCTAssertNil(detector.lastActive(for: 4))
    }
}
