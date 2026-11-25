import Foundation

/// A watched agent process, resolved for display: which tool, where it runs,
/// and whether it is mid-turn right now.
public struct AgentSession: Identifiable, Equatable {
    public let id: pid_t
    public let pid: pid_t
    public let ppid: pid_t
    public let ruleID: String          // the rule this session is grouped under
    public let processName: String
    public let displayName: String     // preset name if known, else the rule name
    public let folder: String          // best-effort cwd, "" if unavailable
    public let isWorking: Bool
    public let startedAt: Date
    public let lastActive: Date
    /// Session name reported by the agent (a T3 Code thread title), if any.
    public var title: String?
    /// App that launched the session ("T3 Code"), if known.
    public var host: String?

    public init(pid: pid_t, ppid: pid_t, ruleID: String, processName: String, displayName: String,
                folder: String, isWorking: Bool, startedAt: Date, lastActive: Date) {
        self.id = pid
        self.pid = pid
        self.ppid = ppid
        self.ruleID = ruleID
        self.processName = processName
        self.displayName = displayName
        self.folder = folder
        self.isWorking = isWorking
        self.startedAt = startedAt
        self.lastActive = lastActive
    }

    /// Short readable name for the folder: the project name, with T3 Code's
    /// generated folders cleaned up ("coloring (worktree)" for
    /// ~/.t3/worktrees/coloring/t3-1a2b..., "check if crema code can" for
    /// ~/.t3/scratch/2026-11-25-check-if-crema-code-can-5c2ecd38).
    public var folderLabel: String {
        guard !folder.isEmpty else { return "" }
        let parts = folder.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(of: "worktrees"), index > 0, parts[index - 1] == ".t3",
           index + 1 < parts.count {
            return parts[index + 1] + " (worktree)"
        }
        if let last = parts.last, parts.dropLast().last == "scratch", parts.contains(".t3") {
            var slug = last
            if let date = slug.range(of: #"^\d{4}-\d{2}-\d{2}-"#, options: .regularExpression) {
                slug.removeSubrange(date)
            }
            if let hash = slug.range(of: #"-[0-9a-f]{8}$"#, options: .regularExpression) {
                slug.removeSubrange(hash)
            }
            return slug.replacingOccurrences(of: "-", with: " ")
        }
        return folder == NSHomeDirectory() ? "~" : (parts.last ?? folder)
    }

    /// Folder shown in the UI, home collapsed to "~".
    public var shortFolder: String {
        guard !folder.isEmpty else { return "" }
        let home = NSHomeDirectory()
        if folder == home { return "~" }
        if folder.hasPrefix(home + "/") {
            return "~" + folder.dropFirst(home.count)
        }
        return folder
    }
}
