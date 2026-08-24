import XCTest
@testable import CremaCore

final class RuleEngineTests: XCTestCase {

    private func proc(_ pid: pid_t, _ name: String, path: String = "", cwd: String = "") -> ScannedProcess {
        ScannedProcess(pid: pid, ppid: 1, name: name, path: path, cpuNanos: 0,
                       startTime: Date(timeIntervalSince1970: 1000), cwd: cwd)
    }

    /// The Claude Code case: basename is a version number, but the path has a
    /// "claude" component, so the agent rule must still match it.
    func testVersionDirLauncherMatchesByPath() {
        let engine = RuleEngine()
        let claude = proc(501, "2.1.241",
                          path: "/Users/k/.local/share/claude/versions/2.1.241")
        let result = engine.evaluate(rules: Rule.defaults(), processes: [claude], workingPIDs: [501])
        XCTAssertTrue(result.agentHolds.contains("Claude Code (1 working)"))
    }

    func testAgentWorkingProducesHoldWithCount() {
        let engine = RuleEngine()
        let rules = Rule.defaults()
        let processes = [proc(101, "claude"), proc(102, "claude"), proc(103, "ffmpeg")]
        let working: Set<pid_t> = [101]   // one claude mid-turn, one idle

        let result = engine.evaluate(rules: rules, processes: processes, workingPIDs: working)

        XCTAssertEqual(result.workingSessionCount, 1)
        XCTAssertTrue(result.agentHolds.contains("Claude Code (1 working)"))
        XCTAssertTrue(result.processHolds.contains("ffmpeg running"))
    }

    func testAppBundleProcessIgnoredByAgentRule() {
        let engine = RuleEngine()
        // Anthropic's Claude desktop app and its helpers live in a .app bundle
        // and must never be treated as a Claude Code CLI session.
        let desktopApp = proc(700, "Claude",
                              path: "/Applications/Claude.app/Contents/MacOS/Claude")
        let helper = proc(701, "Claude Helper (Renderer)",
                          path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)")

        let result = engine.evaluate(rules: Rule.defaults(),
                                     processes: [desktopApp, helper],
                                     workingPIDs: [700, 701])
        XCTAssertTrue(result.agentHolds.isEmpty, "GUI app should not hold as an agent")
        XCTAssertEqual(result.workingSessionCount, 0)

        let sessions = engine.sessions(rules: Rule.defaults(),
                                       processes: [desktopApp, helper],
                                       workingPIDs: [700, 701], lastActive: { _ in nil })
        XCTAssertTrue(sessions.isEmpty, "GUI app should not appear as a session")
    }

    func testIdleAgentsProduceNoAgentHold() {
        let engine = RuleEngine()
        let processes = [proc(201, "claude"), proc(202, "codex")]
        let result = engine.evaluate(rules: Rule.defaults(), processes: processes, workingPIDs: [])
        XCTAssertTrue(result.agentHolds.isEmpty)
        XCTAssertEqual(result.workingSessionCount, 0)
    }

    func testDisabledRuleIsIgnored() {
        let engine = RuleEngine()
        var rules = Rule.defaults()
        for i in rules.indices where rules[i].pattern == "claude" { rules[i].enabled = false }
        let processes = [proc(301, "claude")]
        let result = engine.evaluate(rules: rules, processes: processes, workingPIDs: [301])
        XCTAssertTrue(result.agentHolds.isEmpty)
    }

    func testHandlesManySessions() {
        let engine = RuleEngine()
        // 30 claude sessions, every other one working.
        let processes = (0..<30).map { i in
            proc(pid_t(1000 + i), "claude", path: "/x/claude/v/2.0",
                 cwd: "/Users/k/proj\(i)")
        }
        let working = Set(processes.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element.pid })

        let result = engine.evaluate(rules: Rule.defaults(), processes: processes, workingPIDs: working)
        XCTAssertEqual(result.workingSessionCount, 15)

        let sessions = engine.sessions(rules: Rule.defaults(), processes: processes,
                                       workingPIDs: working, lastActive: { _ in nil })
        XCTAssertEqual(sessions.count, 30)
        // All working sessions sort ahead of all waiting ones.
        let firstWaitingIndex = sessions.firstIndex { !$0.isWorking } ?? sessions.count
        XCTAssertTrue(sessions.prefix(firstWaitingIndex).allSatisfy(\.isWorking))
        XCTAssertEqual(sessions.prefix(15).filter(\.isWorking).count, 15)
    }

    func testSessionsSortWorkingFirst() {
        let engine = RuleEngine()
        let processes = [proc(401, "claude", cwd: "/tmp/a"), proc(402, "claude", cwd: "/tmp/b")]
        let sessions = engine.sessions(
            rules: Rule.defaults(), processes: processes, workingPIDs: [402],
            lastActive: { _ in nil }
        )
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first?.pid, 402)   // the working one is on top
        XCTAssertTrue(sessions.first?.isWorking ?? false)
        XCTAssertEqual(sessions.first?.displayName, "Claude Code")
    }
}
