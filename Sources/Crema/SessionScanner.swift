import Foundation
import CremaCore

protocol SessionScanning {
    func run(rules: [Rule], now: Date) -> SessionScanner.Output
}

/// Called serially off the main actor. Power controls are applied separately
/// so a slow scan cannot overwrite a newer user choice.
final class SessionScanner: SessionScanning {
    struct Output {
        var processes: [ScannedProcess] = []
        var workingPIDs: Set<pid_t> = []
        var lastActive: [pid_t: Date] = [:]
    }

    private let scanner = ProcessScanner()
    private let detector = TurnDetector()
    private let activity = SessionActivityProbe()

    func run(rules: [Rule], now: Date) -> Output {
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

        return Output(
            processes: processes,
            workingPIDs: working,
            lastActive: Dictionary(uniqueKeysWithValues: processes.compactMap { process in
                detector.lastActive(for: process.pid).map { (process.pid, $0) }
            })
        )
    }
}
