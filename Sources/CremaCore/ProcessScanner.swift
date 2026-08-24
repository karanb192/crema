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
    public let ppid: pid_t
    public let name: String        // executable basename
    public let path: String        // full executable path
    public let cpuNanos: UInt64     // cumulative CPU time (user + system), nanoseconds
    public let startTime: Date      // process start
    public var cwd: String          // best-effort working directory, "" if unavailable

    public init(pid: pid_t, ppid: pid_t, name: String, path: String = "",
                cpuNanos: UInt64, startTime: Date, cwd: String) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.path = path
        self.cpuNanos = cpuNanos
        self.startTime = startTime
        self.cwd = cwd
    }

    /// Lowercased path components plus the basename, for rule matching.
    public var tokens: Set<String> {
        var set = Set(path.split(separator: "/").map { $0.lowercased() })
        set.insert(name.lowercased())
        return set
    }

    /// True when `pattern` names this process: an exact token (a path
    /// component or the basename), or a substring of the basename.
    public func matches(pattern: String) -> Bool {
        let needle = pattern.lowercased()
        if name.lowercased().contains(needle) { return true }
        return tokens.contains(needle)
    }
}

/// Reads the live process table with libproc. Same-user processes only need
/// no elevated privileges; anything we cannot read is skipped, never guessed.
public struct ProcessScanner {

    public init() {}

    public func snapshot() -> [ScannedProcess] {
        var result: [ScannedProcess] = []
        for pid in Self.allPIDs() where pid > 0 {
            guard let info = Self.info(for: pid) else { continue }
            result.append(info)
        }
        return result
    }

    static func allPIDs() -> [pid_t] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        let capacity = Int(needed) / MemoryLayout<pid_t>.stride + 16
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0,
            &pids, Int32(capacity * MemoryLayout<pid_t>.stride)
        )
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<pid_t>.stride
        return Array(pids.prefix(count))
    }

    static func info(for pid: pid_t) -> ScannedProcess? {
        // Executable path -> basename. Buffer is 4*MAXPATHLEN, the documented
        // maximum for proc_pidpath (the PROC_PIDPATHINFO_MAXSIZE C macro does
        // not import into Swift, so we use its literal value).
        let maxPath = 4 * 1024
        var pathBuffer = [CChar](repeating: 0, count: maxPath)
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(maxPath))
        guard pathLen > 0 else { return nil }
        let path = String(cString: pathBuffer)
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }

        // BSD info -> ppid and start time.
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bsdRet = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize)
        guard bsdRet == bsdSize else { return nil }
        let ppid = pid_t(bsd.pbi_ppid)
        let startTime = Date(timeIntervalSince1970:
            Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1_000_000.0)

        // Task info -> cumulative CPU nanoseconds.
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let taskRet = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize)
        let cpuNanos: UInt64 = (taskRet == taskSize)
            ? task.pti_total_user &+ task.pti_total_system
            : 0

        return ScannedProcess(
            pid: pid, ppid: ppid, name: name, path: path,
            cpuNanos: cpuNanos, startTime: startTime,
            cwd: cwd(for: pid)
        )
    }

    /// Working directory via PROC_PIDVNODEPATHINFO. Works for the caller's own
    /// processes; returns "" when the OS declines (never a fabricated path).
    static func cwd(for pid: pid_t) -> String {
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
