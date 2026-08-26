import Foundation

/// Evaluates the rule set against a process snapshot and the set of working
/// pids, producing the reasons to hold the Mac awake. Agent holds and process
/// holds are kept separate so the power decision can pick the icon state.
public struct RuleEngine {

    public struct Result: Equatable {
        public var agentHolds: [String]     // "Claude Code (2 working)"
        public var processHolds: [String]   // "ffmpeg running"
        public var workingSessionCount: Int
        /// Batch rules whose process exists right now, enabled or not. Batch
        /// rows are transient in the UI (shown only while running), so this
        /// must not depend on `enabled`, or toggling one off would make the
        /// row vanish before it could be toggled back.
        public var runningBatchRuleIDs: [String]
    }

    public init() {}

    public func evaluate(rules: [Rule],
                         processes: [ScannedProcess],
                         workingPIDs: Set<pid_t>) -> Result {
        var agentHolds: [String] = []
        var processHolds: [String] = []
        var workingCount = 0
        var runningBatch: [String] = []

        for rule in rules {
            // Agent rules ignore GUI apps (e.g. Claude.app); batch rules may
            // legitimately watch an app, so only filter bundles for agents.
            let matched = processes.filter {
                rule.matches($0) && !(rule.kind == .whileAgentWorking && $0.isInAppBundle)
            }
            guard !matched.isEmpty else { continue }

            switch rule.kind {
            case .whileAgentWorking:
                guard rule.enabled else { continue }
                let working = matched.filter { workingPIDs.contains($0.pid) }
                if !working.isEmpty {
                    workingCount += working.count
                    agentHolds.append("\(rule.displayName) (\(working.count) working)")
                }
            case .whileProcessRuns:
                runningBatch.append(rule.id)
                if rule.enabled {
                    processHolds.append("\(rule.displayName) running")
                }
            }
        }

        return Result(agentHolds: agentHolds,
                      processHolds: processHolds,
                      workingSessionCount: workingCount,
                      runningBatchRuleIDs: runningBatch)
    }

    /// Builds display sessions for every process matched by an enabled agent
    /// rule, marking each working or waiting.
    public func sessions(rules: [Rule],
                         processes: [ScannedProcess],
                         workingPIDs: Set<pid_t>,
                         lastActive: (pid_t) -> Date?) -> [AgentSession] {
        let agentPatterns = rules.filter { $0.enabled && $0.kind == .whileAgentWorking }
        var sessions: [AgentSession] = []

        for proc in processes {
            guard !proc.isInAppBundle,
                  let rule = agentPatterns.first(where: { $0.matches(proc) })
            else { continue }
            let preset = AgentPresets.preset(for: proc)
            sessions.append(AgentSession(
                pid: proc.pid,
                ppid: proc.ppid,
                ruleID: rule.id,
                processName: proc.name,
                displayName: preset?.displayName ?? rule.displayName,
                folder: proc.cwd,
                isWorking: workingPIDs.contains(proc.pid),
                startedAt: proc.startTime,
                lastActive: lastActive(proc.pid) ?? proc.startTime
            ))
        }

        // Working first, then longest-idle, so the actionable rows sit on top.
        return sessions.sorted {
            if $0.isWorking != $1.isWorking { return $0.isWorking }
            return $0.lastActive > $1.lastActive
        }
    }
}
