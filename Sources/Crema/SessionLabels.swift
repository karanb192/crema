import Foundation
import CremaCore

extension AgentSession {
    /// Short readable name for the folder: the project name, with T3 Code's
    /// generated folders cleaned up ("coloring (worktree)" for
    /// ~/.t3/worktrees/coloring/t3-1a2b..., "check if crema code can" for
    /// ~/.t3/scratch/2026-11-25-check-if-crema-code-can-5c2ecd38).
    var folderLabel: String {
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
}
