import Foundation

/// Whether a directory is a git repo root. The single source of truth for "is this a repo",
/// shared by the `⌘⇧P` picker's branch glyph and lazygit's git gating. Pure — no AppKit.
enum GitRepo {
    /// True when `dir` contains a `.git` entry (a directory normally, or a file for
    /// worktrees/submodules; `fileExists` matches both).
    static func isGitRepo(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path)
    }
}
