import Foundation

/// Whether a directory is a git repo root. The single source of truth for "is this a repo",
/// shared by the `⌘⇧P` picker's branch glyph and the tool floats' `git:` gating. Pure — no AppKit.
enum GitRepo {
    /// True when `dir` contains a `.git` entry (a directory normally, or a file for
    /// worktrees/submodules; `fileExists` matches both).
    static func isGitRepo(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path)
    }

    /// The enclosing git repo root for `cwd` — walks up looking for `isGitRepo` — or
    /// nil when `cwd` isn't inside a repo. Each probe is filesystem I/O, so callers on the
    /// main thread should walk once per event, not per consumer.
    static func repoRoot(for cwd: URL?) -> URL? {
        guard var dir = cwd?.standardizedFileURL else { return nil }
        while true {
            if isGitRepo(dir) { return dir }
            let parent = dir.deletingLastPathComponent()
            // Stop when the path stops SHRINKING, not when parent == dir: `deletingLastPathComponent()`
            // is not monotonic. On a URL vended by FileManager (`homeDirectoryForCurrentUser`,
            // `temporaryDirectory`) it walks past "/" into "/..", "/../..", … without ever repeating,
            // so an equality check spins forever on the main thread. Identical paths from
            // `URL(fileURLWithPath:)` terminate — the provenance decides, and callers can't see it.
            guard parent.path.count < dir.path.count else { return nil }
            dir = parent
        }
    }
}
