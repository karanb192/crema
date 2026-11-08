import Foundation

/// Decides whether each watched process is "working" (mid-turn) or "waiting"
/// (idle at a prompt) from the CPU it and its descendants used between scans.
///
/// An agent mid-turn burns CPU itself or in tool subprocesses (a build, a test
/// run); an agent parked at a prompt sits near zero. The agent's own CPU rate
/// is checked each scan. Its descendants' CPU, including children that already
/// exited, is averaged over a longer window against a higher bar, because an
/// idle agent still runs brief helpers (a status line every few seconds) that
/// must not read as work. A short "sticky" window keeps a session marked
/// working for a few seconds after its last burst so pauses do not flap it.
public final class TurnDetector {

    public struct Config {
        /// Cores-used by the process itself above which it counts as working.
        public var workingThreshold: Double = 0.04
        /// Average cores-used by its descendants over `descendantWindow` above
        /// which the process counts as working. Sustained tool work (a build,
        /// a test run) sits near a full core; periodic helpers stay far below.
        public var descendantThreshold: Double = 0.2
        public var descendantWindow: TimeInterval = 30
        /// Rates are measured over at least this long, the normal scan
        /// interval. A scan triggered right after another (a menu action)
        /// must not turn a small burst into a high rate.
        public var minimumRateSpan: TimeInterval = 5
        /// Keep a session "working" for this long after its last active sample.
        public var stickySeconds: TimeInterval = 8
        /// A transcript write newer than this counts the session as working,
        /// even when it is network-bound and using no CPU. Wide on purpose:
        /// an agent appends nothing while a single tool call runs (issue #20).
        /// The cost: after the last write a session stays working for this
        /// window plus `stickySeconds`, and the grace window starts after that.
        public var fileActiveWindow: TimeInterval = 150
        public init() {}
    }

    private struct Sample {
        var startTime: Date
        var ppid: pid_t
        var ownNanos: UInt64
        var reapedNanos: UInt64
        var at: Date
        var lastActive: Date
        /// Recent (scan time, seconds since previous scan, descendant CPU).
        var descendantHistory: [(at: Date, elapsed: TimeInterval, nanos: UInt64)] = []
    }

    private var samples: [pid_t: Sample] = [:]
    private var lastScanAt: Date?
    private let config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Feed a fresh scan; returns the set of pids currently considered working.
    /// A process is working if its subtree's CPU burst is recent (sticky) OR it
    /// wrote to its transcript recently. `now` and `lastWrite` are injectable so
    /// the logic is deterministic under test.
    @discardableResult
    public func update(processes: [ScannedProcess],
                       now: Date = Date(),
                       lastWrite: ((ScannedProcess) -> Date?)? = nil) -> Set<pid_t> {
        var working: Set<pid_t> = []
        var live: [pid_t: Sample] = [:]
        let own = cpuSinceLastScan(processes)
        let subtree = Self.subtreeTotals(of: own.withReaped, processes: processes)

        for proc in processes {
            let previous = samples[proc.pid].flatMap { $0.startTime == proc.startTime ? $0 : nil }
            // A never-before-seen process starts idle: seed lastActive far in
            // the past so the sticky window cannot count "just launched" as
            // working. Only a real CPU burst or transcript write marks it.
            var lastActive = previous?.lastActive ?? .distantPast
            var history = previous?.descendantHistory ?? []

            // An unreadable counter skips this scan for the process: the last
            // good sample stays, time included, so the next good reading spans
            // the whole gap and is never measured against a bad baseline.
            if !proc.cpuReadable {
                if var kept = previous {
                    if let written = lastWrite?(proc),
                       now.timeIntervalSince(written) <= config.fileActiveWindow {
                        kept.lastActive = max(kept.lastActive, now)
                    }
                    if now.timeIntervalSince(kept.lastActive) <= config.stickySeconds {
                        working.insert(proc.pid)
                    }
                    live[proc.pid] = kept
                }
                continue
            }

            if let prev = previous {
                let elapsed = now.timeIntervalSince(prev.at)
                if elapsed > 0 {
                    let ownNanos = own.selfOnly[proc.pid] ?? 0
                    let total = subtree[proc.pid] ?? 0
                    history.append((now, elapsed, total > ownNanos ? total - ownNanos : 0))
                    history.removeAll { now.timeIntervalSince($0.at) > config.descendantWindow }
                    let span = history.reduce(0) { $0 + $1.elapsed }
                    let descendantNanos = history.reduce(UInt64(0)) { $0 &+ $1.nanos }
                    let ownCores = Double(ownNanos) / 1_000_000_000.0 / max(elapsed, config.minimumRateSpan)
                    let descendantCores = Double(descendantNanos) / 1_000_000_000.0 / max(span, config.minimumRateSpan)
                    if ownCores >= config.workingThreshold || descendantCores >= config.descendantThreshold {
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

            // These counters only grow for one process, so a lower reading is a
            // failed read; keeping the last good value stops the next good read
            // from counting the process's whole history as one interval.
            live[proc.pid] = Sample(startTime: proc.startTime, ppid: proc.ppid,
                                    ownNanos: max(proc.cpuNanos, previous?.ownNanos ?? 0),
                                    reapedNanos: max(proc.childCPUNanos, previous?.reapedNanos ?? 0),
                                    at: now, lastActive: lastActive, descendantHistory: history)
        }

        samples = live   // drops pids that have exited
        lastScanAt = now
        return working
    }

    /// CPU each process used since the previous scan: its own delta alone, and
    /// that plus the growth in CPU of children it reaped. Deltas are per
    /// process, so a child that exits cannot cancel work elsewhere in the
    /// subtree.
    private func cpuSinceLastScan(_ processes: [ScannedProcess])
        -> (selfOnly: [pid_t: UInt64], withReaped: [pid_t: UInt64]) {
        let current = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        func isLive(_ pid: pid_t, _ sample: Sample) -> Bool {
            current[pid]?.startTime == sample.startTime
        }

        // An exited process's CPU up to the last scan was already counted.
        // Its reaping parent sees that CPU again in its reaped total, so credit
        // it to the nearest ancestor that is still alive.
        var alreadyCounted: [pid_t: UInt64] = [:]
        for (pid, gone) in samples where !isLive(pid, gone) {
            var ancestor = gone.ppid
            var hops = 0
            while let sample = samples[ancestor], !isLive(ancestor, sample), hops < 64 {
                ancestor = sample.ppid
                hops += 1
            }
            alreadyCounted[ancestor, default: 0] &+= gone.ownNanos &+ gone.reapedNanos
        }

        var selfOnly: [pid_t: UInt64] = [:]
        var withReaped: [pid_t: UInt64] = [:]
        for proc in processes where proc.cpuReadable {
            if let prev = samples[proc.pid], prev.startTime == proc.startTime {
                let own = proc.cpuNanos >= prev.ownNanos ? proc.cpuNanos - prev.ownNanos : 0
                let reaped = proc.childCPUNanos >= prev.reapedNanos ? proc.childCPUNanos - prev.reapedNanos : 0
                let credit = alreadyCounted[proc.pid] ?? 0
                selfOnly[proc.pid] = own
                withReaped[proc.pid] = own &+ (reaped > credit ? reaped - credit : 0)
            } else if let lastScanAt, proc.startTime > lastScanAt {
                // Started since the last scan, so all of its CPU is new.
                selfOnly[proc.pid] = proc.cpuNanos
                withReaped[proc.pid] = proc.cpuNanos &+ proc.childCPUNanos
            }
        }
        return (selfOnly, withReaped)
    }

    /// Sums `values` over each process and its live descendants. Iterative,
    /// and a ppid cycle (possible when a pid is reused mid-scan) is cut instead
    /// of recursing forever.
    private static func subtreeTotals(of values: [pid_t: UInt64],
                                      processes: [ScannedProcess]) -> [pid_t: UInt64] {
        var children: [pid_t: [pid_t]] = [:]
        for proc in processes where proc.ppid != proc.pid {
            children[proc.ppid, default: []].append(proc.pid)
        }
        var totals: [pid_t: UInt64] = [:]
        var entered: Set<pid_t> = []
        for root in processes.map(\.pid) where !entered.contains(root) {
            var stack: [(pid: pid_t, childrenDone: Bool)] = [(root, false)]
            while let (pid, childrenDone) = stack.popLast() {
                if childrenDone {
                    var sum = values[pid] ?? 0
                    for child in children[pid] ?? [] { sum &+= totals[child] ?? 0 }
                    totals[pid] = sum
                    continue
                }
                guard entered.insert(pid).inserted else { continue }
                stack.append((pid, true))
                for child in children[pid] ?? [] where !entered.contains(child) {
                    stack.append((child, false))
                }
            }
        }
        return totals
    }

    public func lastActive(for pid: pid_t) -> Date? {
        samples[pid]?.lastActive
    }

    public func forget(pid: pid_t) {
        samples[pid] = nil
    }
}
