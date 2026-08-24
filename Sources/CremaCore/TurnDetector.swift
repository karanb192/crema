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
    /// `now` is injectable so the logic is deterministic under test.
    @discardableResult
    public func update(processes: [ScannedProcess], now: Date = Date()) -> Set<pid_t> {
        var working: Set<pid_t> = []
        var live: [pid_t: Sample] = [:]

        for proc in processes {
            let previous = samples[proc.pid]
            var lastActive = previous?.lastActive ?? proc.startTime

            if let prev = previous {
                let elapsed = now.timeIntervalSince(prev.at)
                if elapsed > 0 {
                    // CPU time can only grow; guard against counter resets.
                    let deltaNanos = proc.cpuNanos >= prev.cpuNanos
                        ? Double(proc.cpuNanos - prev.cpuNanos) : 0
                    let coresUsed = (deltaNanos / 1_000_000_000.0) / elapsed
                    if coresUsed >= config.workingThreshold {
                        lastActive = now
                    }
                }
            }

            let isSticky = now.timeIntervalSince(lastActive) <= config.stickySeconds
            if isSticky { working.insert(proc.pid) }

            live[proc.pid] = Sample(cpuNanos: proc.cpuNanos, at: now, lastActive: lastActive)
        }

        samples = live   // drops pids that have exited
        return working
    }

    public func lastActive(for pid: pid_t) -> Date? {
        samples[pid]?.lastActive
    }

    public func forget(pid: pid_t) {
        samples[pid] = nil
    }
}
