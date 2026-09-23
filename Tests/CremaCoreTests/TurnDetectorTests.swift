import XCTest
@testable import CremaCore

final class TurnDetectorTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 2000)

    private func proc(pid: pid_t, ppid: pid_t = 1, name: String = "claude",
                      cpuNanos: UInt64) -> ScannedProcess {
        ScannedProcess(pid: pid, ppid: ppid, name: name, path: "/usr/bin/\(name)",
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

    /// The agent process idles while its tool subprocess burns CPU (a build,
    /// a test run): the subtree makes the agent read as working (issue #20).
    func testChildProcessCPUCountsTowardAgent() {
        let detector = TurnDetector()
        _ = detector.update(processes: [
            proc(pid: 10, cpuNanos: 500_000_000),
            proc(pid: 11, ppid: 10, name: "zsh", cpuNanos: 0),
        ], now: start)
        // Agent CPU flat, child burns a full core-second.
        let working = detector.update(processes: [
            proc(pid: 10, cpuNanos: 500_000_000),
            proc(pid: 11, ppid: 10, name: "zsh", cpuNanos: 1_000_000_000),
        ], now: start.addingTimeInterval(1))
        XCTAssertTrue(working.contains(10))
    }

    /// A grandchild counts too: agent -> shell -> compiler.
    func testGrandchildCPUCountsTowardAgent() {
        let detector = TurnDetector()
        let quiet: [ScannedProcess] = [
            proc(pid: 20, cpuNanos: 0),
            proc(pid: 21, ppid: 20, name: "zsh", cpuNanos: 0),
            proc(pid: 22, ppid: 21, name: "swift", cpuNanos: 0),
        ]
        _ = detector.update(processes: quiet, now: start)
        let working = detector.update(processes: [
            proc(pid: 20, cpuNanos: 0),
            proc(pid: 21, ppid: 20, name: "zsh", cpuNanos: 0),
            proc(pid: 22, ppid: 21, name: "swift", cpuNanos: 2_000_000_000),
        ], now: start.addingTimeInterval(1))
        XCTAssertTrue(working.contains(20))
    }

    /// A child exiting shrinks the subtree sum; that must read as "no burst
    /// this tick", never as a counter reset that marks the agent working.
    func testChildExitDoesNotMarkWorking() {
        var config = TurnDetector.Config()
        config.stickySeconds = 8
        let detector = TurnDetector(config: config)
        _ = detector.update(processes: [
            proc(pid: 30, cpuNanos: 0),
            proc(pid: 31, ppid: 30, name: "zsh", cpuNanos: 5_000_000_000),
        ], now: start)
        let working = detector.update(
            processes: [proc(pid: 30, cpuNanos: 0)],
            now: start.addingTimeInterval(20))
        XCTAssertFalse(working.contains(30))
    }

    /// A transcript write two minutes old is still inside the widened window:
    /// a single tool call appends nothing while it runs (issue #20).
    func testTranscriptWriteWithinWidenedWindowMarksWorking() {
        let detector = TurnDetector()
        let p = proc(pid: 12, cpuNanos: 0)
        _ = detector.update(processes: [p], now: start)
        let working = detector.update(processes: [p], now: start.addingTimeInterval(130)) { _ in
            self.start.addingTimeInterval(10)
        }
        XCTAssertTrue(working.contains(12))
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
