import Foundation

/// One entry in the `⌘P` repo picker: a directory under the scan root.
struct RepoEntry: Equatable {
    let url: URL
    let name: String
    let isGitRepo: Bool
}

/// Lists the immediate subdirectories of a scan root (default `~/dev`) for the repo
/// picker. Files are ignored; a directory is flagged `isGitRepo` when it contains a
/// `.git` child. Pure — no AppKit — so it can be exercised in isolation.
enum RepoScanner {
    /// The default scan root: `~/dev`. On the case-insensitive macOS filesystem this
    /// also resolves a `~/Dev` directory.
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev", isDirectory: true)
    }

    /// Whether `dir` is a git repo root — it contains a `.git` entry (a dir normally, or a
    /// file for worktrees/submodules; `fileExists` matches both). The single source of truth
    /// for "is this a repo", shared by the picker and lazygit's git gating.
    static func isGitRepo(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path)
    }

    /// Immediate subdirectories of `root`, alphabetical by name (case-insensitive).
    /// Missing/unreadable root → empty list.
    static func scan(root: URL) -> [RepoEntry] {
        let fm = FileManager.default
        guard
            let children = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        return children.compactMap { url -> RepoEntry? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            return RepoEntry(url: url, name: url.lastPathComponent, isGitRepo: isGitRepo(url))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
