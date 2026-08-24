import XCTest
@testable import CremaCore

final class TurnDetectorTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 2000)

    private func proc(pid: pid_t, cpuNanos: UInt64) -> ScannedProcess {
        ScannedProcess(pid: pid, ppid: 1, name: "claude", path: "/usr/bin/claude",
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

    func testRecentTranscriptWriteMarksWorking() {
        let detector = TurnDetector()
        let p = proc(pid: 5, cpuNanos: 0)
        _ = detector.update(processes: [p], now: start)
        // No CPU growth at all, but a transcript write 5s ago -> working.
        let working = detector.update(processes: [p], now: start.addingTimeInterval(10)) { _ in
            self.start.addingTimeInterval(5)
        }
        XCTAssertTrue(working.contains(5))
    }

    func testOldTranscriptWriteDoesNotMarkWorking() {
        let detector = TurnDetector()
        let p = proc(pid: 6, cpuNanos: 0)
        _ = detector.update(processes: [p], now: start)
        // Last write is 200s old, well past the file-active window.
        let working = detector.update(processes: [p], now: start.addingTimeInterval(200)) { _ in
            self.start
        }
        XCTAssertFalse(working.contains(6))
    }

    func testFirstObservationIsIdle() {
        let detector = TurnDetector()
        // A never-before-seen process, even one that started seconds ago, must
        // not be reported working until real activity is observed.
        let fresh = ScannedProcess(pid: 7, ppid: 1, name: "claude", path: "/usr/bin/claude",
                                   cpuNanos: 0, startTime: start, cwd: "")
        let working = detector.update(processes: [fresh], now: start.addingTimeInterval(2))
        XCTAssertFalse(working.contains(7))
    }

    func testExitedProcessIsForgotten() {
        let detector = TurnDetector()
        _ = detector.update(processes: [proc(pid: 4, cpuNanos: 0)], now: start)
        _ = detector.update(processes: [], now: start.addingTimeInterval(1))
        XCTAssertNil(detector.lastActive(for: 4))
    }
}
