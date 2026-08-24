import Foundation

/// Evaluates the rule set against a process snapshot and the set of working
/// pids, producing the reasons to hold the Mac awake. Agent holds and process
/// holds are kept separate so the power decision can pick the icon state.
public struct RuleEngine {

    public struct Result: Equatable {
        public var agentHolds: [String]     // "Claude Code (2 working)"
        public var processHolds: [String]   // "ffmpeg running"
        public var workingSessionCount: Int
    }

    public init() {}

    public func evaluate(rules: [Rule],
                         processes: [ScannedProcess],
                         workingPIDs: Set<pid_t>) -> Result {
        var agentHolds: [String] = []
        var processHolds: [String] = []
        var workingCount = 0

        for rule in rules where rule.enabled {
            let matched = processes.filter { rule.matches($0) }
            guard !matched.isEmpty else { continue }

            switch rule.kind {
            case .whileAgentWorking:
                let working = matched.filter { workingPIDs.contains($0.pid) }
                if !working.isEmpty {
                    workingCount += working.count
                    agentHolds.append("\(rule.displayName) (\(working.count) working)")
                }
            case .whileProcessRuns:
                processHolds.append("\(rule.displayName) running")
            }
        }

        return Result(agentHolds: agentHolds,
                      processHolds: processHolds,
                      workingSessionCount: workingCount)
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
            guard let rule = agentPatterns.first(where: { $0.matches(proc) })
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
