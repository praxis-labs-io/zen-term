import Foundation

/// Git facts about a directory, read straight off the filesystem: whether it is a repo, and what
/// branch it is on. The single source of truth for both, shared by the `⌘P` picker, Settings →
/// Workspaces and the tool floats' `git:` gating. Pure — no AppKit, and no subprocess.
enum GitRepo {
    /// True when `dir` contains a `.git` entry (a directory normally, or a file for
    /// worktrees/submodules; `fileExists` matches both).
    static func isGitRepo(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path)
    }

    /// The branch checked out at `dir`, or nil when it isn't a repo or its `HEAD` can't be read.
    /// A detached HEAD answers with its short commit, which is what a person standing on one needs.
    static func currentBranch(_ dir: URL) -> String? {
        guard let head = headFile(for: dir),
            let text = try? String(contentsOf: head, encoding: .utf8)
        else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("ref: ") else {
            return line.isEmpty ? nil : String(line.prefix(7))
        }
        let ref = String(line.dropFirst("ref: ".count))
        guard ref.hasPrefix("refs/heads/") else { return ref.isEmpty ? nil : ref }
        return String(ref.dropFirst("refs/heads/".count))
    }

    /// `dir`'s `HEAD`. A `.git` directory holds it directly; a worktree or submodule has `.git` as
    /// a file pointing at the real git dir, which holds a `HEAD` of its own.
    private static func headFile(for dir: URL) -> URL? {
        let dotGit = dir.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return dotGit.appendingPathComponent("HEAD") }
        guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
            let path = pointer.split(whereSeparator: \.isNewline)
                .first(where: { $0.hasPrefix("gitdir:") })
                .map({ $0.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces) }),
            !path.isEmpty
        else { return nil }
        let gitDir =
            path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : dir.appendingPathComponent(path).standardizedFileURL
        return gitDir.appendingPathComponent("HEAD")
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
