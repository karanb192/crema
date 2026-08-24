import XCTest
@testable import CremaCore

final class RuleEngineTests: XCTestCase {

    private func proc(_ pid: pid_t, _ name: String, cwd: String = "") -> ScannedProcess {
        ScannedProcess(pid: pid, ppid: 1, name: name, cpuNanos: 0,
                       startTime: Date(timeIntervalSince1970: 1000), cwd: cwd)
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
