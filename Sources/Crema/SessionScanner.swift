import Foundation
import CremaCore

protocol SessionScanning {
    func run(rules: [Rule], now: Date) -> SessionScanner.Output
}

/// Called serially off the main actor. Power controls are applied separately
/// so a slow scan cannot overwrite a newer user choice.
final class SessionScanner: SessionScanning {
    struct Details: Equatable {
        var title: String?
        var host: String?
    }

    struct Output {
        var processes: [ScannedProcess] = []
        var workingPIDs: Set<pid_t> = []
        var lastActive: [pid_t: Date] = [:]
        var details: [pid_t: Details] = [:]
    }

    private let scanner = ProcessScanner()
    private let detector = TurnDetector()
    private let activity = SessionActivityProbe()
    private let t3Titles = T3ThreadTitles()

    /// T3 titles change rarely, so the database is read at most this often,
    /// and right away when a session id appears that has not been looked up.
    private let titleRefreshInterval: TimeInterval = 30
    private var titleCache: [String: String] = [:]
    private var titleCacheIDs: Set<String> = []
    private var titleCacheAt: Date = .distantPast

    func run(rules: [Rule], now: Date) -> Output {
        var processes = scanner.snapshot()

        let agentRules = rules.filter { $0.enabled && $0.kind == .whileAgentWorking }
        func isAgentProcess(_ p: ScannedProcess) -> Bool {
            !p.isInAppBundle && !p.isAgentHelper && agentRules.contains { $0.matches(p) }
        }

        // Resolve cwd, argv and Claude's own session record only for the
        // agent processes that need them.
        var claudeSessions: [pid_t: ClaudeSessionInfo] = [:]
        var sessionIDs: [pid_t: String] = [:]
        for index in processes.indices where isAgentProcess(processes[index]) {
            let process = processes[index]
            let args = ProcessScanner.arguments(for: process.pid)
            switch AgentPresets.preset(for: process)?.id {
            case "claude":
                if Self.isClaudeHelper(args, executableName: process.name) {
                    processes[index].isAgentHelper = true
                    continue
                }
                let info = activity.claudeSession(pid: process.pid)
                claudeSessions[process.pid] = info
                if let id = info?.sessionID ?? Self.claudeSessionID(args) { sessionIDs[process.pid] = id }
            case "codex":
                if Self.isCodexHelper(args) {
                    processes[index].isAgentHelper = true
                    continue
                }
            default:
                break
            }
            processes[index].cwd = ProcessScanner.cwd(for: process.pid)
        }

        // A cwd shared by more than one live agent process cannot use the
        // directory-wide transcript signal, or an idle sibling would inherit a
        // busy sibling's writes. Those fall back to the CPU signal only, unless
        // the exact session is known.
        var cwdCounts: [String: Int] = [:]
        for p in processes where isAgentProcess(p) && !p.cwd.isEmpty {
            cwdCounts[p.cwd, default: 0] += 1
        }

        let working = detector.update(processes: processes, now: now) { [activity] proc in
            guard let preset = AgentPresets.preset(for: proc), preset.id == "claude" else { return nil }
            // Claude's own busy/idle status is the most direct signal.
            if let busy = claudeSessions[proc.pid]?.isBusy { return busy ? now : nil }
            if let sessionID = sessionIDs[proc.pid] {
                return activity.lastClaudeWrite(cwd: proc.cwd, sessionID: sessionID)
            }
            guard (cwdCounts[proc.cwd] ?? 0) <= 1 else { return nil }
            return activity.lastClaudeWrite(cwd: proc.cwd)
        }

        let t3 = threadTitles(for: Set(sessionIDs.values), now: now)
        var details: [pid_t: Details] = [:]
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        for process in processes where isAgentProcess(process) {
            let info = claudeSessions[process.pid]
            let title = sessionIDs[process.pid].flatMap { t3[$0] } ?? info?.name
            let host = Self.hostApp(of: process, in: byPID) ?? info?.hostName
            if title != nil || host != nil { details[process.pid] = Details(title: title, host: host) }
        }

        return Output(
            processes: processes,
            workingPIDs: working,
            lastActive: Dictionary(uniqueKeysWithValues: processes.compactMap { process in
                detector.lastActive(for: process.pid).map { (process.pid, $0) }
            }),
            details: details
        )
    }

    private func threadTitles(for ids: Set<String>, now: Date) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        if !ids.isSubset(of: titleCacheIDs) || now.timeIntervalSince(titleCacheAt) >= titleRefreshInterval {
            titleCache = t3Titles.titles(forSessionIDs: ids)
            titleCacheIDs = ids
            titleCacheAt = now
        }
        return titleCache
    }

    /// The nearest ancestor that is a GUI app ("T3 Code", "Ghostty", "Code"),
    /// named after its bundle. Nil for daemons and unreadable chains.
    static func hostApp(of process: ScannedProcess, in byPID: [pid_t: ScannedProcess]) -> String? {
        var pid = process.ppid
        for _ in 0..<32 where pid > 1 {
            guard let ancestor = byPID[pid] else { return nil }
            if let range = ancestor.path.range(of: ".app/Contents/MacOS/") {
                let bundlePath = String(ancestor.path[..<range.lowerBound])
                return (bundlePath as NSString).lastPathComponent
            }
            pid = ancestor.ppid
        }
        return nil
    }

    /// Claude's session id from `--session-id X`, `--resume X` or the `=` forms.
    static func claudeSessionID(_ args: [String]) -> String? {
        for (index, arg) in args.enumerated() {
            for flag in ["--session-id", "--resume"] {
                if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
                if arg == flag, index + 1 < args.count, !args[index + 1].hasPrefix("-") { return args[index + 1] }
            }
        }
        return nil
    }

    /// Processes that run Claude Code's binary but are not sessions: the
    /// background daemon ("claude daemon run"), its "claude bg-pty-host" /
    /// "claude bg-spare" workers, and bundled tools it starts under another
    /// name (argv[0] "ugrep" for a search).
    static func isClaudeHelper(_ args: [String], executableName: String) -> Bool {
        guard let first = args.first else { return false }
        let argv0 = (first as NSString).lastPathComponent
        if argv0 != "claude" && argv0 != executableName { return true }
        if args.dropFirst().first == "daemon" { return true }
        return args.contains { $0.hasPrefix("--bg-") }
    }

    /// The Codex app server's supervisor ("codex app-server daemon ...") sits
    /// beside the real server process and never does work itself.
    static func isCodexHelper(_ args: [String]) -> Bool {
        guard let index = args.firstIndex(of: "app-server") else { return false }
        return args.dropFirst(index + 1).first == "daemon"
    }
}
