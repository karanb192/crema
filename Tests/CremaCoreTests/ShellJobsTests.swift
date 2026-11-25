import XCTest
@testable import CremaCore

final class ShellJobTrackerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func proc(_ pid: pid_t, _ ppid: pid_t, _ name: String, startedAfter seconds: TimeInterval,
              cpu: UInt64 = 0) -> ScannedProcess {
        ScannedProcess(pid: pid, ppid: ppid, name: name, path: "/bin/" + name,
                       cpuNanos: cpu, startTime: t0.addingTimeInterval(seconds), cwd: "")
    }

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testCountsAgentShellAndNamesBusiestCommand() {
        let agent = proc(100, 1, "claude", startedAfter: 0)
        let all = [agent,
                   proc(101, 100, "sh", startedAfter: 0),             // launch wrapper
                   proc(102, 100, "node", startedAfter: 60),          // MCP server, not a shell
                   proc(103, 100, "zsh", startedAfter: 600),          // Bash tool call
                   proc(104, 103, "bash", startedAfter: 601),
                   proc(105, 104, "sleep", startedAfter: 602, cpu: 9_000),
                   proc(106, 104, "xcodebuild", startedAfter: 602, cpu: 5_000),
                   proc(107, 106, "DTServiceHub", startedAfter: 603, cpu: 100)]
        let jobs = ShellJobTracker().update(agents: [agent], processes: all, now: at(700))
        XCTAssertEqual(jobs[100], [.init(shellPID: 103, label: "xcodebuild")])
    }

    func testBriefShellsDoNotCount() {
        let agent = proc(100, 1, "claude", startedAfter: 0)
        let hook = proc(103, 100, "sh", startedAfter: 600)
        XCTAssertTrue(ShellJobTracker().update(agents: [agent], processes: [agent, hook], now: at(605)).isEmpty)
    }

    func testStalledJobStopsCountingAndProgressRevivesIt() {
        let tracker = ShellJobTracker()
        let agent = proc(100, 1, "claude", startedAfter: 0)
        let shell = proc(103, 100, "zsh", startedAfter: 100)
        func scan(_ cpu: UInt64, _ time: TimeInterval) -> Bool {
            let tool = proc(104, 103, "server", startedAfter: 101, cpu: cpu)
            return !tracker.update(agents: [agent], processes: [agent, shell, tool], now: at(time)).isEmpty
        }
        XCTAssertTrue(scan(0, 200))                     // first seen: counts
        XCTAssertTrue(scan(0, 200 + 600))               // still inside the stall window
        XCTAssertFalse(scan(0, 200 + 601))              // no CPU for 10 min: stalled
        XCTAssertFalse(scan(1_000_000_000, 900))        // one CPU-second: not enough
        XCTAssertTrue(scan(6_000_000_000, 1_000))       // six CPU-seconds: progress again
        XCTAssertTrue(scan(6_000_000_000, 1_000 + 600))
        XCTAssertFalse(scan(6_000_000_000, 1_000 + 601))
    }

    func testNothingCountsPastMaximumAge() {
        let tracker = ShellJobTracker()
        let agent = proc(100, 1, "claude", startedAfter: 0)
        let shell = proc(103, 100, "zsh", startedAfter: 100)
        var cpu: UInt64 = 0
        var last = false
        for minute in stride(from: 2.0, through: 190.0, by: 2.0) {
            cpu += 2_000_000_000
            let tool = proc(104, 103, "xcodebuild", startedAfter: 101, cpu: cpu)
            last = !tracker.update(agents: [agent], processes: [agent, shell, tool], now: at(100 + minute * 60)).isEmpty
            if minute == 178 { XCTAssertTrue(last) }
        }
        XCTAssertFalse(last)
    }

    func testShellOfOnlySleepHasNoLabel() {
        let agent = proc(100, 1, "claude", startedAfter: 0)
        let all = [agent, proc(103, 100, "zsh", startedAfter: 60), proc(104, 103, "sleep", startedAfter: 61)]
        let jobs = ShellJobTracker().update(agents: [agent], processes: all, now: at(120))
        XCTAssertEqual(jobs[100], [.init(shellPID: 103, label: nil)])
    }
}
