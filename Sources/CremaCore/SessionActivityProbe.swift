import Foundation

/// The precise per-session turn signal: how recently an agent wrote to its own
/// transcript. An agent mid-turn appends on every message and tool call, even
/// while it is network-bound and burning almost no local CPU. An agent parked
/// at a prompt does not write at all until you reply.
///
/// Claude Code is implemented precisely here: it maps a session's working
/// directory to its transcript folder under ~/.claude/projects. Other agents
/// fall back to the CPU signal until their layout is added.
public struct SessionActivityProbe {
    private let fileManager = FileManager.default
    private let projectsRoot: String

    public init(projectsRoot: String = ("~/.claude/projects" as NSString).expandingTildeInPath) {
        self.projectsRoot = projectsRoot
    }

    /// Last transcript write for a Claude Code session with this working
    /// directory, or nil if none is found. `cwd` comes from the process scanner.
    /// Claude encodes the project path by replacing every "/" with "-".
    public func lastClaudeWrite(cwd: String) -> Date? {
        guard !cwd.isEmpty else { return nil }
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        let dir = projectsRoot + "/" + encoded
        return newestModification(inDirectory: dir, suffix: ".jsonl")
    }

    private func newestModification(inDirectory dir: String, suffix: String) -> Date? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir) else { return nil }
        var newest: Date?
        for name in names where name.hasSuffix(suffix) {
            let path = dir + "/" + name
            guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            if newest == nil || modified > newest! { newest = modified }
        }
        return newest
    }
}
