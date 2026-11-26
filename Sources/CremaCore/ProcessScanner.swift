import Foundation
import Darwin

/// One process as seen by the scanner.
///
/// `name` is the executable basename, which for launchers like Claude Code is a
/// version number (".../share/claude/versions/2.1.241"), not "claude". So
/// matching goes through `tokens`, the set of path components plus the name,
/// where "claude" does appear.
public struct ScannedProcess: Equatable {
    public let pid: pid_t
    public internal(set) var ppid: pid_t
    public let name: String        // executable basename
    public let path: String        // full executable path
    public internal(set) var cpuNanos: UInt64      // cumulative CPU time (user + system), nanoseconds
    public internal(set) var childCPUNanos: UInt64 // CPU of children this process has reaped, nanoseconds
    /// False when the scan skipped this process's CPU counters (it is outside
    /// every watched agent's process tree); both CPU values are then 0.
    public internal(set) var hasCPU = true
    public let startTime: Date      // process start
    public var cwd: String          // best-effort working directory, "" if unavailable
    /// Set by the session scanner for an agent's own background helpers
    /// (Claude Code's daemon and its bg-pty-host / bg-spare processes). They
    /// share the agent's binary but are not sessions.
    public var isAgentHelper = false
    /// Lowercased path components plus the basename, for rule matching.
    /// Computed once: matching runs per process, per rule, several times a scan.
    public let tokens: Set<String>
    private let lowercasedName: String

    public init(pid: pid_t, ppid: pid_t, name: String, path: String = "",
                cpuNanos: UInt64, childCPUNanos: UInt64 = 0, startTime: Date, cwd: String) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.path = path
        self.cpuNanos = cpuNanos
        self.childCPUNanos = childCPUNanos
        self.startTime = startTime
        self.cwd = cwd
        self.lowercasedName = name.lowercased()
        self.isInAppBundle = Self.utf8(path, contains: "/Contents/MacOS/") || Self.utf8(path, contains: ".app/")
        var tokens = Set(path.split(separator: "/").map { $0.lowercased() })
        tokens.insert(lowercasedName)
        self.tokens = tokens
    }

    /// True when the executable lives inside a .app bundle. Installed CLI
    /// agents never do, so this filters out GUI apps (Anthropic's Claude
    /// desktop app and its "Claude Helper" processes) from agent matching.
    /// Computed once at init: it is checked for every process on every pass.
    public let isInAppBundle: Bool

    /// True when `pattern` names this process: an exact token (a path
    /// component or the basename), or a substring of the basename.
    ///
    /// Runs for every process against every rule several times a scan, so the
    /// substring test compares UTF-8 bytes with memmem. Foundation's
    /// `contains` walks Characters and was most of a scan's CPU. Byte
    /// comparison does not treat composed and decomposed accents as equal,
    /// which agent and tool names never need.
    public func matches(pattern: String) -> Bool {
        let needle = pattern.lowercased()
        if Self.utf8(lowercasedName, contains: needle) { return true }
        return tokens.contains(needle)
    }

    static func utf8(_ haystack: String, contains needle: String) -> Bool {
        var haystack = haystack, needle = needle
        return haystack.withUTF8 { h in
            needle.withUTF8 { n in
                guard !n.isEmpty else { return false }   // as Foundation: "" matches nothing
                guard n.count <= h.count, let hBase = h.baseAddress, let nBase = n.baseAddress else { return false }
                return memmem(hBase, h.count, nBase, n.count) != nil
            }
        }
    }
}

/// Reads the live process table with libproc. Same-user processes only need
/// no elevated privileges; anything we cannot read is skipped, never guessed.
///
/// A scan has two phases. Every process gets its parent, start time and
/// executable path, which rule matching needs; the path is cached per
/// (pid, start time, command name), since it only changes on exec. The CPU
/// counters, the costly part, are read only for the process trees the caller
/// asks for. Use one scanner for repeated scans so the cache carries over;
/// it is not thread-safe.
public final class ProcessScanner {

    private struct CachedIdentity {
        var startTime: Date
        var command: String
        var pathReadAt: Date
        var process: ScannedProcess
    }
    private var identities: [pid_t: CachedIdentity] = [:]
    private var pathBuffer = [CChar](repeating: 0, count: 4 * 1024)

    public init() {}

    /// Every readable process, with CPU counters for all of them.
    public func snapshot() -> [ScannedProcess] {
        snapshot(readingCPUOf: { _ in true })
    }

    /// Every readable process; CPU counters only for processes where
    /// `readsCPU` is true and all of their descendants. The others come back
    /// with `hasCPU == false`. A process whose counters cannot be read is
    /// dropped, as a failed path or BSD read drops any process.
    public func snapshot(readingCPUOf readsCPU: (ScannedProcess) -> Bool) -> [ScannedProcess] {
        var processes: [ScannedProcess] = []
        var seen: [pid_t: CachedIdentity] = [:]
        for pid in Self.allPIDs() where pid > 0 {
            guard let identity = identity(for: pid) else { continue }
            seen[pid] = identity
            processes.append(identity.process)
        }
        identities = seen   // drops exited pids

        var children: [pid_t: [Int]] = [:]
        for (index, process) in processes.enumerated() where process.ppid != process.pid {
            children[process.ppid, default: []].append(index)
        }
        var stack = processes.indices.filter { readsCPU(processes[$0]) }
        var tracked = Set<Int>()
        while let index = stack.popLast() {
            guard tracked.insert(index).inserted else { continue }
            stack.append(contentsOf: children[processes[index].pid] ?? [])
        }

        var unreadable = Set<Int>()
        for index in processes.indices {
            guard tracked.contains(index) else {
                processes[index].hasCPU = false
                continue
            }
            guard let cpu = Self.cpu(for: processes[index].pid) else {
                unreadable.insert(index)
                continue
            }
            processes[index].cpuNanos = cpu.own
            processes[index].childCPUNanos = cpu.reaped
        }
        guard !unreadable.isEmpty else { return processes }
        return processes.indices.filter { !unreadable.contains($0) }.map { processes[$0] }
    }

    /// Parent, start time and path, the path reused while the process keeps
    /// the same start time and command name.
    private func identity(for pid: pid_t) -> CachedIdentity? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { return nil }
        let ppid = pid_t(bsd.pbi_ppid)
        let startTime = Date(timeIntervalSince1970:
            Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1_000_000.0)
        let command = withUnsafeBytes(of: bsd.pbi_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }

        let now = Date()
        if var cached = identities[pid], cached.startTime == startTime, cached.command == command,
           !Self.needsPathRefresh(startTime: startTime, pathReadAt: cached.pathReadAt, now: now) {
            // Reparenting (to launchd when a parent exits) keeps the identity.
            cached.process.ppid = ppid
            return cached
        }

        // Executable path -> basename. Buffer is 4*MAXPATHLEN, the documented
        // maximum for proc_pidpath (the PROC_PIDPATHINFO_MAXSIZE C macro does
        // not import into Swift, so we use its literal value).
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLen > 0 else { return nil }
        let path = String(decoding: pathBuffer.prefix(Int(pathLen)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }
        // cwd is left empty here and filled in lazily only for the few agent
        // processes that need it.
        let process = ScannedProcess(pid: pid, ppid: ppid, name: name, path: path,
                                     cpuNanos: 0, childCPUNanos: 0, startTime: startTime, cwd: "")
        return CachedIdentity(startTime: startTime, command: command, pathReadAt: now, process: process)
    }

    /// Exec keeps the pid and start time, and keeps the command name when the
    /// new program has the same basename (a launcher shim exec'ing the real
    /// tool). A path read in a process's first seconds may predate such an
    /// exec, so it is read once more after that window; later reads are final.
    static func needsPathRefresh(startTime: Date, pathReadAt: Date, now: Date,
                                 execWindow: TimeInterval = 2) -> Bool {
        pathReadAt.timeIntervalSince(startTime) < execWindow
            && now.timeIntervalSince(startTime) >= execWindow
    }

    /// Own and reaped-children CPU in nanoseconds, or nil when either counter
    /// is unreadable. A guessed value would become a baseline that the next
    /// good reading is measured against.
    static func cpu(for pid: pid_t) -> (own: UInt64, reaped: UInt64)? {
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize,
              let own = nanos(fromTicks: task.pti_total_user &+ task.pti_total_system)
        else { return nil }

        // A child that starts and exits between two scans is never in a
        // snapshot; its CPU only shows up in the parent's reaped total.
        var usage = rusage_info_v2()
        let usageRet = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard usageRet == 0,
              let reaped = nanos(fromTicks: usage.ri_child_user_time &+ usage.ri_child_system_time)
        else { return nil }
        return (own, reaped)
    }

    static func allPIDs() -> [pid_t] {
        let stride = MemoryLayout<pid_t>.stride
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }

        // proc_listpids gives no "buffer was too small" signal: a completely
        // full buffer is indistinguishable from an exact fit. So if the fill
        // comes back full (processes appeared between the sizing and fill
        // calls), grow and retry rather than silently truncating the table.
        var capacity = Int(needed) / stride + 32
        for _ in 0..<6 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(capacity * stride))
            guard written > 0 else { return [] }
            let count = Int(written) / stride
            if count < capacity {
                return Array(pids.prefix(count))
            }
            capacity *= 2   // buffer was full; there may be more
        }
        return []
    }

    /// PROC_PIDTASKINFO and proc_pid_rusage report CPU time in Mach
    /// absolute-time ticks, not nanoseconds. On Intel a tick is 1 ns, but on
    /// Apple Silicon it is 125/3 ns, so raw values undercount CPU about 41x.
    static func nanos(fromTicks ticks: UInt64) -> UInt64? {
        guard let timebase = timebaseCache.value() else { return nil }
        return nanos(fromTicks: ticks, numer: timebase.numer, denom: timebase.denom)
    }

    /// Split so the multiply cannot overflow for any realistic CPU total.
    static func nanos(fromTicks ticks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
        guard numer != denom, denom != 0 else { return ticks }
        let n = UInt64(numer), d = UInt64(denom)
        return (ticks / d) * n + (ticks % d) * n / d
    }

    /// The process's argv, plus only the named environment variables, via
    /// KERN_PROCARGS2; empty when the OS declines. Read only for the few agent
    /// processes that need it. The rest of the environment is never copied.
    /// macOS hides the environment of Apple platform binaries; agents are not.
    public static func commandLine(for pid: pid_t, environmentKeys: Set<String> = [])
        -> (arguments: [String], environment: [String: String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return ([], [:]) }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return ([], [:]) }
        return parseProcArgs(Array(buffer.prefix(size)), environmentKeys: environmentKeys)
    }

    /// Parses a KERN_PROCARGS2 buffer: argc (Int32), the exec path, NUL
    /// padding, argc NUL-terminated arguments, then NUL-terminated KEY=VALUE
    /// environment strings up to an empty one.
    static func parseProcArgs(_ buffer: [UInt8], environmentKeys: Set<String>)
        -> (arguments: [String], environment: [String: String]) {
        let size = buffer.count
        guard size > MemoryLayout<Int32>.size else { return ([], [:]) }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // exec path
        while index < size, buffer[index] == 0 { index += 1 }   // padding
        func nextString() -> String {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }
        var args: [String] = []
        while args.count < Int(argc), index < size { args.append(nextString()) }
        var environment: [String: String] = [:]
        while index < size, !environmentKeys.isEmpty {
            let entry = nextString()
            if entry.isEmpty { break }
            if let equals = entry.firstIndex(of: "="),
               environmentKeys.contains(String(entry[..<equals])) {
                environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
            }
        }
        return (args, environment)
    }

    /// Working directory via PROC_PIDVNODEPATHINFO. Works for same-user
    /// processes; returns "" when the OS declines (never a fabricated path).
    public static func cwd(for pid: pid_t) -> String {
        var vpi = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, size)
        guard ret == size else { return "" }
        return withUnsafeBytes(of: &vpi.pvi_cdir.vip_path) { raw -> String in
            let ptr = raw.bindMemory(to: CChar.self).baseAddress!
            return String(cString: ptr)
        }
    }
}

/// Caches only a successful lookup, so a failed call is retried next scan
/// instead of pinning the scanner to raw ticks.
private let timebaseCache = TimebaseCache()

private final class TimebaseCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: mach_timebase_info_data_t?

    func value() -> mach_timebase_info_data_t? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer != 0, info.denom != 0 else { return nil }
        cached = info
        return info
    }
}
