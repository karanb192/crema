import Foundation

/// The two ways a tool finishes, and therefore the two ways a rule holds.
public enum RuleKind: String, Codable, Equatable {
    /// Hold while a matching process exists at all. For batch tools that exit
    /// when done: ffmpeg, rsync, brew, xcodebuild.
    case whileProcessRuns
    /// Hold only while a matching process is mid-turn. For agents that never
    /// exit but go quiet between turns: claude, codex, gemini.
    case whileAgentWorking
}

/// A watch rule. `pattern` is matched against a process's executable basename;
/// a leading and trailing match is exact, otherwise it is a substring match.
public struct Rule: Identifiable, Equatable, Codable {
    public var id: String
    public var displayName: String
    public var pattern: String
    public var kind: RuleKind
    public var enabled: Bool

    public init(id: String = UUID().uuidString,
                displayName: String,
                pattern: String,
                kind: RuleKind,
                enabled: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.pattern = pattern
        self.kind = kind
        self.enabled = enabled
    }

    public func matches(_ process: ScannedProcess) -> Bool {
        process.matches(pattern: pattern)
    }

    /// The default rule set: one agent rule per tier-1 preset (on), plus an
    /// example batch rule for ffmpeg (off until a matching process appears).
    public static func defaults() -> [Rule] {
        var rules = AgentPresets.tier1.map { preset in
            Rule(id: "agent." + preset.id,
                 displayName: preset.displayName,
                 pattern: preset.processName,
                 kind: .whileAgentWorking,
                 enabled: true)
        }
        rules.append(Rule(id: "batch.ffmpeg",
                          displayName: "ffmpeg",
                          pattern: "ffmpeg",
                          kind: .whileProcessRuns,
                          enabled: true))
        return rules
    }
}
