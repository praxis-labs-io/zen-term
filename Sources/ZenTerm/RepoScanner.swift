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
            let isGit = fm.fileExists(atPath: url.appendingPathComponent(".git").path)
            return RepoEntry(url: url, name: url.lastPathComponent, isGitRepo: isGit)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
