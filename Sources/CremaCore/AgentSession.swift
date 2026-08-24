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
