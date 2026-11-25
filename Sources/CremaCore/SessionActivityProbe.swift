import Foundation

/// What Claude Code reports about one of its own processes in
/// `<config dir>/sessions/<pid>.json`. Every field is optional: the file is not
/// a documented format, so anything missing falls back to the other signals.
public struct ClaudeSessionInfo: Equatable {
    public var sessionID: String?
    public var name: String?        // session title, e.g. a T3 Code thread name
    public var status: String?      // "busy" while mid-turn, "idle" at a prompt
    public var entrypoint: String?  // e.g. "t3-code"
    public var cwd: String?         // the session's project directory

    public init(sessionID: String? = nil, name: String? = nil,
                status: String? = nil, entrypoint: String? = nil, cwd: String? = nil) {
        self.sessionID = sessionID
        self.name = name
        self.status = status
        self.entrypoint = entrypoint
        self.cwd = cwd
    }

    /// True or false when Claude reported a known status, nil otherwise.
    public var isBusy: Bool? {
        switch status {
        case "busy": return true
        case "idle": return false
        default: return nil
        }
    }

    /// Readable name for the app that launched the session, if known.
    public var hostName: String? {
        // Only entrypoints seen in the wild are mapped; unknown ones stay
        // unlabeled rather than showing a raw identifier.
        entrypoint == "t3-code" ? "T3 Code" : nil
    }
}

/// The precise per-session turn signals for Claude Code: its own session
/// record, and how recently it wrote to its transcript. An agent mid-turn
/// appends as each message and tool result lands, even while it is
/// network-bound and burning almost no local CPU, but appends nothing while a
/// single tool call runs. An agent parked at a prompt does not write at all
/// until you reply. Other agents fall back to the CPU signal.
public struct SessionActivityProbe {
    private let fileManager = FileManager.default
    private let projectsRoot: String
    private let sessionsRoot: String

    public init(projectsRoot: String = ("~/.claude/projects" as NSString).expandingTildeInPath,
                sessionsRoot: String = ("~/.claude/sessions" as NSString).expandingTildeInPath) {
        self.projectsRoot = projectsRoot
        self.sessionsRoot = sessionsRoot
    }

    /// A probe for one Claude Code config directory: `CLAUDE_CONFIG_DIR` when
    /// the process sets it (a second account, for example), else ~/.claude.
    public init(claudeConfigDir: String) {
        self.init(projectsRoot: claudeConfigDir + "/projects", sessionsRoot: claudeConfigDir + "/sessions")
    }

    /// Claude Code names a project folder after its path with every UTF-16
    /// code unit that is not an ASCII letter or digit replaced by "-". So
    /// "/Users/me/.t3/my_app" becomes "-Users-me--t3-my-app".
    public static func encodeProjectPath(_ cwd: String) -> String {
        String(cwd.utf16.map { unit -> Character in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return Character(Unicode.Scalar(unit)!)
            default: return "-"
            }
        })
    }

    /// Reads `sessions/<pid>.json`, or nil if absent, unreadable, or left by an
    /// earlier process that had the same pid. `processStart` is the kernel's
    /// start time for the live process. Claude writes `startedAt` a second or
    /// more after launch, later on a busy Mac, so only a record that predates
    /// the process belongs to someone else.
    public func claudeSession(pid: pid_t, processStart: Date) -> ClaudeSessionInfo? {
        let path = sessionsRoot + "/\(pid).json"
        guard let data = fileManager.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        if let filePID = json["pid"] as? Int, filePID != Int(pid) { return nil }
        if let startedMillis = json["startedAt"] as? Double,
           startedMillis / 1000 < processStart.timeIntervalSince1970 - 5 {
            return nil
        }
        return ClaudeSessionInfo(sessionID: json["sessionId"] as? String,
                                 name: json["name"] as? String,
                                 status: json["status"] as? String,
                                 entrypoint: json["entrypoint"] as? String,
                                 cwd: json["cwd"] as? String)
    }

    /// Last transcript write for a Claude Code session with this working
    /// directory, or nil if none is found. With a session id, only that
    /// session's transcript is checked (one stat); without one, the newest
    /// transcript in the project folder counts.
    public func lastClaudeWrite(cwd: String, sessionID: String? = nil) -> Date? {
        guard !cwd.isEmpty else { return nil }
        let dir = projectsRoot + "/" + Self.encodeProjectPath(cwd)
        if let sessionID {
            return modificationDate(dir + "/" + sessionID + ".jsonl")
        }
        return newestModification(inDirectory: dir, suffix: ".jsonl")
    }

    private func modificationDate(_ path: String) -> Date? {
        (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func newestModification(inDirectory dir: String, suffix: String) -> Date? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir) else { return nil }
        var newest: Date?
        for name in names where name.hasSuffix(suffix) {
            guard let modified = modificationDate(dir + "/" + name) else { continue }
            if newest == nil || modified > newest! { newest = modified }
        }
        return newest
    }
}

/// The order Claude Code's signals are trusted in, as one pure function.
/// Returns the moment the session last counted as active, or nil.
public enum ClaudeTurnSignal {
    /// 1. A running shell job the session started: working now, even when
    ///    Claude reports idle while it waits on a background command.
    /// 2. Claude's own busy / idle status.
    /// 3. The session's own transcript, when its id is known.
    /// 4. The newest transcript in its project folder, only when no other
    ///    watched agent shares that folder (`directoryTranscript` is nil then).
    public static func lastActive(hasRunningJob: Bool,
                                  isBusy: Bool?,
                                  sessionTranscript: (() -> Date?)?,
                                  directoryTranscript: (() -> Date?)?,
                                  now: Date) -> Date? {
        if hasRunningJob { return now }
        if let isBusy { return isBusy ? now : nil }
        // A session id taken from argv can be stale (after /clear), pointing
        // at an old transcript, so the folder's newest write wins when allowed.
        let session = sessionTranscript?()
        let directory = directoryTranscript?()
        switch (session, directory) {
        case let (s?, d?): return max(s, d)
        default: return session ?? directory
        }
    }
}
