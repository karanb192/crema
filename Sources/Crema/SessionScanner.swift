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
        var account: String?
        var activity: String?
    }

    struct Output {
        var processes: [ScannedProcess] = []
        var workingPIDs: Set<pid_t> = []
        var lastActive: [pid_t: Date] = [:]
        var details: [pid_t: Details] = [:]
    }

    private let scanner = ProcessScanner()
    private let detector = TurnDetector()
    private let shellJobs = ShellJobTracker()

    /// argv and CLAUDE_CONFIG_DIR never change for a running process, so they
    /// are read once per (pid, start time).
    private struct CommandLine {
        var startTime: Date
        var arguments: [String]
        var configDir: String?
    }
    private var commandLines: [pid_t: CommandLine] = [:]

    func run(rules: [Rule], now: Date) -> Output {
        var processes = scanner.snapshot()

        let agentRules = rules.filter { $0.enabled && $0.kind == .whileAgentWorking }
        func isAgentProcess(_ p: ScannedProcess) -> Bool {
            !p.isInAppBundle && !p.isAgentHelper && agentRules.contains { $0.matches(p) }
        }

        // Resolve argv, Claude's own session record and cwd only for the
        // agent processes that need them.
        var claudeSessions: [pid_t: ClaudeSessionInfo] = [:]
        var sessionIDs: [pid_t: String] = [:]
        var probes: [pid_t: SessionActivityProbe] = [:]
        var accounts: [pid_t: String] = [:]
        var liveCommandLines: [pid_t: CommandLine] = [:]
        for index in processes.indices where isAgentProcess(processes[index]) {
            let process = processes[index]
            let commandLine = commandLines[process.pid].flatMap { $0.startTime == process.startTime ? $0 : nil }
                ?? Self.readCommandLine(process)
            // An empty read (the OS declined, or mid-exec) is retried next scan.
            if !commandLine.arguments.isEmpty { liveCommandLines[process.pid] = commandLine }
            let args = commandLine.arguments

            switch AgentPresets.preset(for: process)?.id {
            case "claude":
                let probe = SessionActivityProbe(claudeConfigDir: commandLine.configDir ?? Self.defaultClaudeConfigDir)
                let info = probe.claudeSession(pid: process.pid, processStart: process.startTime)
                // A session record means a real session, even in a process that
                // started as a pre-spawned background worker.
                if info == nil, Self.isClaudeHelper(args) {
                    processes[index].isAgentHelper = true
                    continue
                }
                probes[process.pid] = probe
                claudeSessions[process.pid] = info
                if let id = info?.sessionID ?? Self.claudeSessionID(args) { sessionIDs[process.pid] = id }
                if let configDir = commandLine.configDir { accounts[process.pid] = Self.accountLabel(configDir: configDir) }
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
        commandLines = liveCommandLines

        // A cwd shared by more than one live agent process cannot use the
        // directory-wide transcript signal, or an idle sibling would inherit a
        // busy sibling's writes.
        var cwdCounts: [String: Int] = [:]
        for p in processes where isAgentProcess(p) && !p.cwd.isEmpty {
            cwdCounts[p.cwd, default: 0] += 1
        }

        let jobs = shellJobs.update(agents: processes.filter { probes[$0.pid] != nil },
                                    processes: processes, now: now)

        let working = detector.update(processes: processes, now: now) { proc in
            guard let probe = probes[proc.pid] else { return nil }
            let info = claudeSessions[proc.pid]
            // Claude's own record of its project path beats the kernel cwd,
            // which a `cd` in the session can move.
            let cwd = info?.cwd ?? proc.cwd
            let sessionTranscript = sessionIDs[proc.pid].map { id in { probe.lastClaudeWrite(cwd: cwd, sessionID: id) } }
            let directoryTranscript: (() -> Date?)? = (cwdCounts[proc.cwd] ?? 0) <= 1
                ? { probe.lastClaudeWrite(cwd: cwd) } : nil
            return ClaudeTurnSignal.lastActive(hasRunningJob: jobs[proc.pid] != nil,
                                               isBusy: info?.isBusy,
                                               sessionTranscript: sessionTranscript,
                                               directoryTranscript: directoryTranscript,
                                               now: now)
        }

        var details: [pid_t: Details] = [:]
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        for process in processes where isAgentProcess(process) {
            let info = claudeSessions[process.pid]
            let detail = Details(title: info?.name,
                                 host: Self.hostApp(of: process, in: byPID) ?? info?.hostName,
                                 account: accounts[process.pid],
                                 activity: jobs[process.pid].map(Self.activityLabel))
            if detail != Details() { details[process.pid] = detail }
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

    private static let defaultClaudeConfigDir = ("~/.claude" as NSString).expandingTildeInPath

    private static func readCommandLine(_ process: ScannedProcess) -> CommandLine {
        let (args, environment) = ProcessScanner.commandLine(for: process.pid,
                                                             environmentKeys: ["CLAUDE_CONFIG_DIR"])
        let configDir = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        return CommandLine(startTime: process.startTime, arguments: args, configDir: configDir)
    }

    /// "personal" for ~/.claude-personal, the folder name for any other
    /// config dir, nil for the default one.
    static func accountLabel(configDir: String) -> String? {
        let standardized = (configDir as NSString).standardizingPath
        guard standardized != defaultClaudeConfigDir else { return nil }
        var name = (standardized as NSString).lastPathComponent
        for prefix in [".claude-", ".claude_", "."] where name.hasPrefix(prefix) && name.count > prefix.count {
            name.removeFirst(prefix.count)
            break
        }
        return name.isEmpty ? nil : name
    }

    /// "xcodebuild running", or a count when several jobs run.
    static func activityLabel(_ jobs: [ShellJobTracker.Job]) -> String {
        if jobs.count == 1 { return jobs[0].label.map { "\($0) running" } ?? "command running" }
        return "\(jobs.count) commands running"
    }

    /// The outermost GUI app above the process ("T3 Code", "Ghostty",
    /// "Visual Studio Code", not its nested helper app). Nil for daemons and
    /// unreadable chains.
    static func hostApp(of process: ScannedProcess, in byPID: [pid_t: ScannedProcess]) -> String? {
        var pid = process.ppid
        for _ in 0..<32 where pid > 1 {
            guard let ancestor = byPID[pid] else { return nil }
            if let range = ancestor.path.range(of: ".app/") {
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

    /// Tools Claude Code ships inside its own binary and runs under their own
    /// name (argv[0] "ugrep" for a search).
    private static let bundledToolNames: Set<String> = ["ugrep", "rg"]

    /// Processes that run Claude Code's binary but are not sessions: the
    /// background daemon ("claude daemon run"), its unclaimed "bg-pty-host" /
    /// "bg-spare" workers, and bundled tools. Only consulted when the process
    /// has no session record, so a claimed worker still counts.
    static func isClaudeHelper(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        if bundledToolNames.contains((first as NSString).lastPathComponent) { return true }
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
