import Foundation

/// A known coding agent we ship a named preset for. The process name is what
/// the scanner matches; the session directory is where the agent writes its
/// transcript (used by the precise turn signal in a later version).
public struct AgentPreset: Equatable {
    public let id: String
    public let displayName: String
    public let processName: String       // executable basename to match
    public let sessionDir: String?       // absolute path, ~ expanded, or nil
    public let tier: Int                 // 1 = shipped signal, 2 = generic only

    public init(id: String, displayName: String, processName: String, sessionDir: String?, tier: Int) {
        self.id = id
        self.displayName = displayName
        self.processName = processName
        self.sessionDir = sessionDir.map { ($0 as NSString).expandingTildeInPath }
        self.tier = tier
    }
}

public enum AgentPresets {
    /// Tier 1 presets. Paths verified present on the developer machine; the
    /// session dir is used as a coarse activity hint, the CPU signal is the
    /// authoritative per-session turn detector today.
    public static let tier1: [AgentPreset] = [
        AgentPreset(id: "claude",  displayName: "Claude Code", processName: "claude",  sessionDir: "~/.claude/projects", tier: 1),
        AgentPreset(id: "codex",   displayName: "Codex CLI",   processName: "codex",   sessionDir: "~/.codex/sessions",  tier: 1),
        AgentPreset(id: "gemini",  displayName: "Gemini CLI",  processName: "gemini",  sessionDir: "~/.gemini/tmp",      tier: 1),
        AgentPreset(id: "copilot", displayName: "Copilot CLI", processName: "copilot", sessionDir: "~/.copilot/logs",    tier: 1),
        AgentPreset(id: "opencode", displayName: "opencode",   processName: "opencode", sessionDir: "~/.local/share/opencode", tier: 1),
    ]

    /// Fast lookup by exact process name.
    public static func preset(forProcess name: String) -> AgentPreset? {
        tier1.first { $0.processName == name }
    }

    /// Lookup by matching a scanned process against each preset's process name,
    /// path-aware so version-dir launchers like Claude Code still resolve.
    public static func preset(for process: ScannedProcess) -> AgentPreset? {
        tier1.first { process.matches(pattern: $0.processName) }
    }

    public static let allProcessNames: Set<String> = Set(tier1.map(\.processName))
}
