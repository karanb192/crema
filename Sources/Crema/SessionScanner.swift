import Foundation
import CremaCore

/// Owns the scan pipeline and runs it OFF the main actor, so the 5-second scan
/// (a full process walk plus a transcript directory read per Claude session)
/// never blocks the UI. All mutable state here (the turn detector, the grace
/// timestamp) is touched only from `run(...)`, which AppModel calls strictly
/// one at a time, so access stays serial without locking.
final class SessionScanner {
    struct Intent {
        var restNow: Bool
        var pinnedUntil: Date?
        var reviewing: Bool
        var now: Date
    }

    struct Output {
        var sessions: [AgentSession]
        var decision: PowerDecision
    }

    private let scanner = ProcessScanner()
    private let detector = TurnDetector()
    private let engine = RuleEngine()
    private let activity = SessionActivityProbe()
    private let graceSeconds: TimeInterval
    private var lastAgentWorkingAt: Date?

    init(graceSeconds: TimeInterval = 600) {
        self.graceSeconds = graceSeconds
    }

    func run(rules: [Rule], intent: Intent) -> Output {
        let now = intent.now
        var processes = scanner.snapshot()

        let agentRules = rules.filter { $0.enabled && $0.kind == .whileAgentWorking }
        func isAgentProcess(_ p: ScannedProcess) -> Bool {
            !p.isInAppBundle && agentRules.contains { $0.matches(p) }
        }

        // Resolve cwd only for the agent processes that need it.
        for index in processes.indices where isAgentProcess(processes[index]) {
            processes[index].cwd = ProcessScanner.cwd(for: processes[index].pid)
        }

        // A cwd shared by more than one live agent process cannot use the
        // directory-wide transcript signal, or an idle sibling would inherit a
        // busy sibling's writes. Those fall back to the CPU signal only.
        var cwdCounts: [String: Int] = [:]
        for p in processes where isAgentProcess(p) && !p.cwd.isEmpty {
            cwdCounts[p.cwd, default: 0] += 1
        }

        let working = detector.update(processes: processes, now: now) { [activity] proc in
            guard let preset = AgentPresets.preset(for: proc), preset.id == "claude" else { return nil }
            guard (cwdCounts[proc.cwd] ?? 0) <= 1 else { return nil }
            return activity.lastClaudeWrite(cwd: proc.cwd)
        }

        let result = engine.evaluate(rules: rules, processes: processes, workingPIDs: working)
        let sessions = engine.sessions(
            rules: rules, processes: processes, workingPIDs: working,
            lastActive: { [detector] pid in detector.lastActive(for: pid) }
        )

        if result.workingSessionCount > 0 { lastAgentWorkingAt = now }
        let graceActive: Bool = {
            guard result.agentHolds.isEmpty, let last = lastAgentWorkingAt else { return false }
            return now.timeIntervalSince(last) <= graceSeconds
        }()

        let input = PowerInputs(
            restNow: intent.restNow,
            pinnedUntil: intent.pinnedUntil,
            reviewing: intent.reviewing,
            agentHolds: result.agentHolds,
            processHolds: result.processHolds,
            workingCount: result.workingSessionCount,
            graceActive: graceActive,
            now: now
        )
        return Output(sessions: sessions, decision: decidePower(input))
    }
}
