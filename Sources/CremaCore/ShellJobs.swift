import Foundation

/// Shell commands an agent started and that are still making progress: a long
/// foreground tool call, or a job it put in the background and will come back
/// to. Claude Code runs every Bash tool call as a child shell of its own
/// process, so a shell child is the agent's own work, never one you started
/// in a terminal.
///
/// Guards against holding the Mac awake for nothing:
/// - a shell must live `minimumAge` before it counts, so brief helpers (a
///   hook, a status line command) never do;
/// - a job counts only while its process tree keeps using CPU: one that adds
///   less than `progressCPU` in `stallTimeout` (a hung command, a mostly
///   idle server) stops counting;
/// - nothing counts past `maximumAge`.
public final class ShellJobTracker {
    public static let shellNames: Set<String> = ["zsh", "bash", "sh", "fish", "dash"]

    public struct Config {
        /// Shells that start this soon after the agent are part of its launch
        /// (a wrapper the host app adds), not tool calls.
        public var launchWindow: TimeInterval = 10
        public var minimumAge: TimeInterval = 15
        public var stallTimeout: TimeInterval = 600
        public var progressCPU: TimeInterval = 5
        public var maximumAge: TimeInterval = 3 * 3600
        public init() {}
    }

    public struct Job: Equatable {
        public let shellPID: pid_t
        /// The busiest non-shell process under the shell ("xcodebuild"), or
        /// nil when only shells and `sleep` run there.
        public let label: String?

        public init(shellPID: pid_t, label: String?) {
            self.shellPID = shellPID
            self.label = label
        }
    }

    private struct Progress {
        var startTime: Date
        var cpuNanos: UInt64
        var lastProgressAt: Date
    }

    private let config: Config
    private var progress: [pid_t: Progress] = [:]

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Running jobs per agent pid, for the given agents. Call once per scan.
    public func update(agents: [ScannedProcess], processes: [ScannedProcess],
                       now: Date) -> [pid_t: [Job]] {
        var children: [pid_t: [ScannedProcess]] = [:]
        for process in processes where process.ppid != process.pid {
            children[process.ppid, default: []].append(process)
        }

        var live: [pid_t: Progress] = [:]
        var result: [pid_t: [Job]] = [:]
        for agent in agents {
            for shell in children[agent.pid] ?? [] where Self.shellNames.contains(shell.name) {
                let age = now.timeIntervalSince(shell.startTime)
                guard shell.startTime.timeIntervalSince(agent.startTime) >= config.launchWindow,
                      age <= config.maximumAge else { continue }

                let tree = Self.subtree(of: shell, children: children)
                let cpu = tree.reduce(UInt64(0)) { $0 &+ $1.cpuNanos &+ $1.childCPUNanos }
                // A job seen for the first time (new, or already running when
                // Crema started) gets one stall window from now to show progress.
                var record = progress[shell.pid].flatMap { $0.startTime == shell.startTime ? $0 : nil }
                    ?? Progress(startTime: shell.startTime, cpuNanos: cpu, lastProgressAt: now)
                if cpu < record.cpuNanos {
                    // A descendant exited and its CPU left the tree: rebase.
                    record.cpuNanos = cpu
                } else if cpu >= record.cpuNanos &+ UInt64(config.progressCPU * 1_000_000_000) {
                    record.cpuNanos = cpu
                    record.lastProgressAt = now
                }
                live[shell.pid] = record

                guard age >= config.minimumAge,
                      now.timeIntervalSince(record.lastProgressAt) <= config.stallTimeout else { continue }
                result[agent.pid, default: []].append(
                    Job(shellPID: shell.pid, label: Self.busiestCommand(in: tree.dropFirst())))
            }
        }
        progress = live
        return result
    }

    /// The shell and every live descendant, the shell first.
    private static func subtree(of root: ScannedProcess,
                                children: [pid_t: [ScannedProcess]]) -> [ScannedProcess] {
        var tree: [ScannedProcess] = []
        var stack = [root]
        var seen: Set<pid_t> = []
        while let process = stack.popLast() {
            guard seen.insert(process.pid).inserted else { continue }
            tree.append(process)
            stack.append(contentsOf: children[process.pid] ?? [])
        }
        return tree
    }

    private static func busiestCommand<S: Sequence>(in processes: S) -> String? where S.Element == ScannedProcess {
        processes
            .filter { !shellNames.contains($0.name) && $0.name != "sleep" }
            .max { $0.cpuNanos < $1.cpuNanos }?
            .name
    }
}
