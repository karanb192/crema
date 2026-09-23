import Foundation

/// Decides whether each watched process is "working" (mid-turn) or "waiting"
/// (idle at a prompt) from its CPU rate between scans.
///
/// An agent mid-turn burns CPU and spawns tool subprocesses; an agent parked
/// at a prompt sits near zero. We measure the CPU-time delta per process across
/// two scans and convert it to cores-used. A short "sticky" window keeps a
/// session marked working for a few seconds after its last burst so streaming
/// pauses do not flap the state.
public final class TurnDetector {

    public struct Config {
        /// Cores-used above which a process counts as actively working.
        public var workingThreshold: Double = 0.04
        /// Keep a session "working" for this long after its last active sample.
        public var stickySeconds: TimeInterval = 8
        /// A transcript write newer than this counts the session as working,
        /// even when it is network-bound and using no CPU. Wide on purpose:
        /// an agent appends nothing while a single tool call runs, so a
        /// medium step (a fetch, an install, a slow API turn) must not flip
        /// the session to waiting between appends (issue #20). Sleep timing
        /// is unaffected; the grace window governs that.
        public var fileActiveWindow: TimeInterval = 150
        public init() {}
    }

    private struct Sample {
        var cpuNanos: UInt64
        var at: Date
        var lastActive: Date
    }

    private var samples: [pid_t: Sample] = [:]
    private let config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Feed a fresh scan; returns the set of pids currently considered working.
    /// A process is working if its CPU burst is recent (sticky) OR it wrote to
    /// its transcript recently. `now` and `lastWrite` are injectable so the
    /// logic is deterministic under test.
    @discardableResult
    public func update(processes: [ScannedProcess],
                       now: Date = Date(),
                       lastWrite: ((ScannedProcess) -> Date?)? = nil) -> Set<pid_t> {
        var working: Set<pid_t> = []
        var live: [pid_t: Sample] = [:]
        let subtree = Self.subtreeNanos(for: processes)

        for proc in processes {
            let previous = samples[proc.pid]
            // A never-before-seen process starts idle: seed lastActive far in
            // the past so the sticky window cannot count "just launched" as
            // working. Only a real CPU burst or transcript write marks it.
            var lastActive = previous?.lastActive ?? .distantPast
            let nanosNow = subtree[proc.pid] ?? proc.cpuNanos

            if let prev = previous {
                let elapsed = now.timeIntervalSince(prev.at)
                if elapsed > 0 {
                    // CPU time can only grow; the guard covers counter resets
                    // and the subtree sum dropping when a child exits.
                    let deltaNanos = nanosNow >= prev.cpuNanos
                        ? Double(nanosNow - prev.cpuNanos) : 0
                    let coresUsed = (deltaNanos / 1_000_000_000.0) / elapsed
                    if coresUsed >= config.workingThreshold {
                        lastActive = now
                    }
                }
            }

            let cpuActive = now.timeIntervalSince(lastActive) <= config.stickySeconds
            let fileActive: Bool = {
                guard let written = lastWrite?(proc) else { return false }
                return now.timeIntervalSince(written) <= config.fileActiveWindow
            }()

            if cpuActive || fileActive {
                working.insert(proc.pid)
                if fileActive { lastActive = max(lastActive, now) }
            }

            live[proc.pid] = Sample(cpuNanos: nanosNow, at: now, lastActive: lastActive)
        }

        samples = live   // drops pids that have exited
        return working
    }

    /// Cumulative CPU of each process plus its live descendants. An agent
    /// mid-turn often burns its CPU in tool subprocesses (a build, a test
    /// run, a subagent) while the agent process itself waits at ~0%, so the
    /// turn signal must watch the whole subtree, not one pid (issue #20).
    private static func subtreeNanos(for processes: [ScannedProcess]) -> [pid_t: UInt64] {
        var childIndexes: [pid_t: [Int]] = [:]
        for (index, proc) in processes.enumerated() where proc.ppid != proc.pid {
            childIndexes[proc.ppid, default: []].append(index)
        }
        var memo: [pid_t: UInt64] = [:]
        func total(_ index: Int) -> UInt64 {
            let proc = processes[index]
            if let cached = memo[proc.pid] { return cached }
            var sum = proc.cpuNanos
            for child in childIndexes[proc.pid] ?? [] {
                sum &+= total(child)
            }
            memo[proc.pid] = sum
            return sum
        }
        for index in processes.indices { _ = total(index) }
        return memo
    }

    public func lastActive(for pid: pid_t) -> Date? {
        samples[pid]?.lastActive
    }

    public func forget(pid: pid_t) {
        samples[pid] = nil
    }
}
