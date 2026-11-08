import XCTest
@testable import CremaCore

final class TurnDetectorTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 2000)

    private func proc(pid: pid_t, ppid: pid_t = 1, name: String = "claude",
                      cpuNanos: UInt64, reaped: UInt64 = 0, readable: Bool = true,
                      startedAt: Date? = nil) -> ScannedProcess {
        ScannedProcess(pid: pid, ppid: ppid, name: name, path: "/usr/bin/\(name)",
                       cpuNanos: cpuNanos, childCPUNanos: reaped, cpuReadable: readable,
                       startTime: startedAt ?? start, cwd: "")
    }

    private let second: UInt64 = 1_000_000_000

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

    /// An idle parent reaping a busy child's history must not read as a
    /// burst: that CPU was counted while the child was alive.
    func testChildExitDoesNotMarkWorking() {
        let detector = TurnDetector()
        _ = detector.update(processes: [
            proc(pid: 30, cpuNanos: 0),
            proc(pid: 31, ppid: 30, name: "zsh", cpuNanos: 5 * second),
        ], now: start)
        let reapedIt = detector.update(
            processes: [proc(pid: 30, cpuNanos: 0, reaped: 5 * second)],
            now: start.addingTimeInterval(20))
        XCTAssertFalse(reapedIt.contains(30))

        let orphanDetector = TurnDetector()
        _ = orphanDetector.update(processes: [
            proc(pid: 30, cpuNanos: 0),
            proc(pid: 31, ppid: 30, name: "zsh", cpuNanos: 5 * second),
        ], now: start)
        let orphaned = orphanDetector.update(
            processes: [proc(pid: 30, cpuNanos: 0)],
            now: start.addingTimeInterval(20))
        XCTAssertFalse(orphaned.contains(30))
    }

    /// A child exiting must not cancel the parent's own CPU in the same tick.
    func testChildExitKeepsBusyParentWorking() {
        let detector = TurnDetector()
        _ = detector.update(processes: [
            proc(pid: 32, cpuNanos: 0),
            proc(pid: 33, ppid: 32, name: "zsh", cpuNanos: 5 * second),
        ], now: start)
        // 0.25s of parent CPU over 5s is 0.05 cores, above the 0.04 threshold.
        let reapedIt = detector.update(
            processes: [proc(pid: 32, cpuNanos: second / 4, reaped: 5 * second)],
            now: start.addingTimeInterval(5))
        XCTAssertTrue(reapedIt.contains(32))

        let orphanDetector = TurnDetector()
        _ = orphanDetector.update(processes: [
            proc(pid: 32, cpuNanos: 0),
            proc(pid: 33, ppid: 32, name: "zsh", cpuNanos: 5 * second),
        ], now: start)
        let orphaned = orphanDetector.update(
            processes: [proc(pid: 32, cpuNanos: second / 4)],
            now: start.addingTimeInterval(5))
        XCTAssertTrue(orphaned.contains(32))
    }

    /// One child exiting must not cancel a busy sibling.
    func testChildExitKeepsBusySiblingCounted() {
        let detector = TurnDetector()
        _ = detector.update(processes: [
            proc(pid: 34, cpuNanos: 0),
            proc(pid: 35, ppid: 34, name: "zsh", cpuNanos: 5 * second),
            proc(pid: 36, ppid: 34, name: "swift", cpuNanos: 0),
        ], now: start)
        let working = detector.update(processes: [
            proc(pid: 34, cpuNanos: 0, reaped: 5 * second),
            proc(pid: 36, ppid: 34, name: "swift", cpuNanos: 2 * second),
        ], now: start.addingTimeInterval(5))
        XCTAssertTrue(working.contains(34))
    }

    /// A shell and its command exiting together: the agent reaps the shell,
    /// whose reaped total holds the command. Only CPU used since the last
    /// scan may count, never the command's whole history again.
    func testShellAndCommandExitingTogetherCountOnlyNewCPU() {
        func run(finalInterval: UInt64) -> Bool {
            let detector = TurnDetector()
            _ = detector.update(processes: [
                proc(pid: 40, cpuNanos: 0),
                proc(pid: 41, ppid: 40, name: "zsh", cpuNanos: second / 10),
                proc(pid: 42, ppid: 41, name: "python3", cpuNanos: 100 * second),
            ], now: start)
            let shellTotal = second / 10 + 100 * second + finalInterval
            return detector.update(
                processes: [proc(pid: 40, cpuNanos: 0, reaped: shellTotal)],
                now: start.addingTimeInterval(5)
            ).contains(40)
        }
        XCTAssertTrue(run(finalInterval: 2 * second), "2s of new CPU in 5s is 0.4 cores")
        XCTAssertFalse(run(finalInterval: 0), "100s of old CPU must not count again")
    }

    /// A child that starts and exits between two scans is never in a
    /// snapshot; its CPU arrives through the parent's reaped total.
    func testShortLivedChildCountsThroughReapedTime() {
        let detector = TurnDetector()
        _ = detector.update(processes: [proc(pid: 50, cpuNanos: 0)], now: start)
        let working = detector.update(
            processes: [proc(pid: 50, cpuNanos: 0, reaped: 2 * second)],
            now: start.addingTimeInterval(5))
        XCTAssertTrue(working.contains(50))
    }

    /// A child born since the last scan counts all of its CPU.
    func testChildBornSinceLastScanCounts() {
        let detector = TurnDetector()
        _ = detector.update(processes: [proc(pid: 52, cpuNanos: 0)], now: start)
        let working = detector.update(processes: [
            proc(pid: 52, cpuNanos: 0),
            proc(pid: 53, ppid: 52, name: "swift", cpuNanos: 2 * second,
                 startedAt: start.addingTimeInterval(3)),
        ], now: start.addingTimeInterval(5))
        XCTAssertTrue(working.contains(52))
    }

    /// A reused pid is a new process: neither the old process's CPU nor a
    /// negative delta against it may leak into the agent.
    func testReusedPidIsTreatedAsNewProcess() {
        let detector = TurnDetector()
        _ = detector.update(processes: [
            proc(pid: 54, cpuNanos: 0),
            proc(pid: 55, ppid: 54, name: "zsh", cpuNanos: 10 * second),
        ], now: start)
        let working = detector.update(processes: [
            proc(pid: 54, cpuNanos: 0, reaped: 10 * second),
            proc(pid: 55, ppid: 54, name: "zsh", cpuNanos: 0,
                 startedAt: start.addingTimeInterval(19)),
        ], now: start.addingTimeInterval(20))
        XCTAssertFalse(working.contains(54))
    }

    /// An idle agent still runs brief helpers, such as a status line every
    /// few seconds. Their CPU is real but must never read as a turn.
    func testPeriodicShortHelpersDoNotMarkWorking() {
        let detector = TurnDetector()
        var reaped: UInt64 = 0
        _ = detector.update(processes: [proc(pid: 70, cpuNanos: 0)], now: start)
        for tick in 1...12 {
            // 0.25s of helper CPU every 5s: 0.05 cores, above the agent's own
            // per-scan bar but far below a sustained build.
            reaped += second / 4
            let working = detector.update(
                processes: [proc(pid: 70, cpuNanos: 0, reaped: reaped)],
                now: start.addingTimeInterval(Double(tick) * 5))
            XCTAssertFalse(working.contains(70), "tick \(tick)")
        }
    }

    /// One burst of descendant work holds the session for the averaging
    /// window plus the sticky window, then lets it go.
    func testDescendantBurstAgesOutOfWindow() {
        let detector = TurnDetector()
        _ = detector.update(processes: [proc(pid: 72, cpuNanos: 0)], now: start)
        var working = detector.update(
            processes: [proc(pid: 72, cpuNanos: 0, reaped: 5 * second)],
            now: start.addingTimeInterval(5))
        XCTAssertTrue(working.contains(72))
        for tick in 2...4 {
            working = detector.update(
                processes: [proc(pid: 72, cpuNanos: 0, reaped: 5 * second)],
                now: start.addingTimeInterval(Double(tick) * 5))
        }
        XCTAssertTrue(working.contains(72), "20s in: past the sticky window, inside the average")
        for tick in 5...9 {
            working = detector.update(
                processes: [proc(pid: 72, cpuNanos: 0, reaped: 5 * second)],
                now: start.addingTimeInterval(Double(tick) * 5))
        }
        XCTAssertFalse(working.contains(72), "45s after one 5s burst")
    }

    /// A scan right after another (a menu action) must not turn one short
    /// helper run into a high rate.
    func testShortScanGapDoesNotInflateRate() {
        let detector = TurnDetector()
        _ = detector.update(processes: [proc(pid: 74, cpuNanos: 0)], now: start)
        let working = detector.update(
            processes: [proc(pid: 74, cpuNanos: second / 50, reaped: second / 5)],
            now: start.addingTimeInterval(0.5))
        XCTAssertFalse(working.contains(74))
    }

    /// A lower counter can only be a bad read. The next good read must not
    /// count the process's whole CPU history as one interval.
    func testFailedReadDoesNotReplayLifetimeCPU() {
        let detector = TurnDetector()
        _ = detector.update(processes: [proc(pid: 76, cpuNanos: 100 * second, reaped: 100 * second)], now: start)
        _ = detector.update(processes: [proc(pid: 76, cpuNanos: 0, reaped: 0)], now: start.addingTimeInterval(5))
        let working = detector.update(
            processes: [proc(pid: 76, cpuNanos: 100 * second, reaped: 100 * second)],
            now: start.addingTimeInterval(10))
        XCTAssertFalse(working.contains(76))
    }

    /// An unreadable first reading must not become the baseline the first
    /// good reading is measured against.
    func testUnreadableFirstReadingIsNotABaseline() {
        let detector = TurnDetector()
        _ = detector.update(processes: [proc(pid: 78, cpuNanos: 0, readable: false)], now: start)
        _ = detector.update(processes: [proc(pid: 78, cpuNanos: 100 * second, reaped: 100 * second)],
                            now: start.addingTimeInterval(5))
        let working = detector.update(
            processes: [proc(pid: 78, cpuNanos: 100 * second, reaped: 100 * second)],
            now: start.addingTimeInterval(10))
        XCTAssertFalse(working.contains(78))
    }

    /// After an unreadable scan, the next good reading is spread over the
    /// whole gap, not charged to one interval.
    func testUnreadableScanSpreadsCatchUpOverTheGap() {
        let detector = TurnDetector()
        _ = detector.update(processes: [proc(pid: 80, cpuNanos: 0)], now: start)
        _ = detector.update(processes: [proc(pid: 80, cpuNanos: 0, readable: false)],
                            now: start.addingTimeInterval(5))
        // 0.25s over 10s is 0.025 cores, under the 0.04 bar.
        let working = detector.update(
            processes: [proc(pid: 80, cpuNanos: second / 4)],
            now: start.addingTimeInterval(10))
        XCTAssertFalse(working.contains(80))
    }

    /// An unreadable scan keeps a session with a fresh transcript working.
    func testUnreadableScanKeepsTranscriptSignal() {
        let detector = TurnDetector()
        _ = detector.update(processes: [proc(pid: 82, cpuNanos: 0)], now: start)
        let working = detector.update(
            processes: [proc(pid: 82, cpuNanos: 0, readable: false)],
            now: start.addingTimeInterval(5)) { _ in self.start.addingTimeInterval(4) }
        XCTAssertTrue(working.contains(82))
    }

    /// A ppid cycle can appear when a pid is reused mid-scan. The walk must
    /// finish instead of recursing until the stack overflows.
    func testParentCycleDoesNotHang() {
        let detector = TurnDetector()
        let cycle = [
            proc(pid: 60, ppid: 61, cpuNanos: 0),
            proc(pid: 61, ppid: 60, name: "zsh", cpuNanos: 0),
        ]
        _ = detector.update(processes: cycle, now: start)
        let working = detector.update(processes: [
            proc(pid: 60, ppid: 61, cpuNanos: second),
            proc(pid: 61, ppid: 60, name: "zsh", cpuNanos: 0),
        ], now: start.addingTimeInterval(1))
        XCTAssertTrue(working.contains(60))
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
