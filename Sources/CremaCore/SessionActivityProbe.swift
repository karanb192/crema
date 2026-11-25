import Foundation

/// What Claude Code reports about one of its own processes in
/// `~/.claude/sessions/<pid>.json`. Every field is optional: the file is not a
/// documented format, so anything missing falls back to the other signals.
public struct ClaudeSessionInfo: Equatable {
    public var sessionID: String?
    public var name: String?        // session title, e.g. a T3 Code thread name
    public var status: String?      // "busy" while mid-turn, "idle" at a prompt
    public var entrypoint: String?  // e.g. "t3-code"

    public init(sessionID: String? = nil, name: String? = nil,
                status: String? = nil, entrypoint: String? = nil) {
        self.sessionID = sessionID
        self.name = name
        self.status = status
        self.entrypoint = entrypoint
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

/// The precise per-session turn signal: how recently an agent wrote to its own
/// transcript. An agent mid-turn appends as each message and tool result lands,
/// even while it is network-bound and burning almost no local CPU, but appends
/// nothing while a single tool call runs. An agent parked at a prompt does not
/// write at all until you reply.
///
/// Claude Code is implemented precisely here: it maps a session's working
/// directory to its transcript folder under ~/.claude/projects. Other agents
/// fall back to the CPU signal until their layout is added.
public struct SessionActivityProbe {
    private let fileManager = FileManager.default
    private let projectsRoot: String
    private let sessionsRoot: String

    public init(projectsRoot: String = ("~/.claude/projects" as NSString).expandingTildeInPath,
                sessionsRoot: String = ("~/.claude/sessions" as NSString).expandingTildeInPath) {
        self.projectsRoot = projectsRoot
        self.sessionsRoot = sessionsRoot
    }

    /// Claude Code names a project folder after its path with every character
    /// that is not an ASCII letter or digit replaced by "-". So
    /// "/Users/me/.t3/my_app" becomes "-Users-me--t3-my-app".
    public static func encodeProjectPath(_ cwd: String) -> String {
        String(cwd.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
    }

    /// Reads `~/.claude/sessions/<pid>.json`, or nil if absent or unreadable.
    public func claudeSession(pid: pid_t) -> ClaudeSessionInfo? {
        let path = sessionsRoot + "/\(pid).json"
        guard let data = fileManager.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        // A stale file from an earlier process with a reused pid is ignored.
        if let filePID = json["pid"] as? Int, filePID != Int(pid) { return nil }
        return ClaudeSessionInfo(sessionID: json["sessionId"] as? String,
                                 name: json["name"] as? String,
                                 status: json["status"] as? String,
                                 entrypoint: json["entrypoint"] as? String)
    }

    /// Last transcript write for a Claude Code session with this working
    /// directory, or nil if none is found. `cwd` comes from the process scanner.
    /// With a session id, only that session's transcript is checked (one stat);
    /// without one, the newest transcript in the project folder counts.
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
