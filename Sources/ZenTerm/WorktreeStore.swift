import CryptoKit
import Foundation

/// One linked working tree of a repo: its own directory and its own branch, sharing the repo's
/// history, refs and stashes with the main checkout.
struct Worktree: Equatable {
    let path: URL
    /// Nil on a detached HEAD, which `git worktree add --detach` and a hand-made worktree produce.
    let branch: String?
    let head: String
    let isLocked: Bool
}

/// What a worktree would lose if it were removed now.
struct WorktreeState: Equatable {
    let uncommitted: Int
    /// Commits on this worktree's HEAD that no remote has. There is no stash count beside it:
    /// `refs/stash` is shared across every worktree of a repo, so a per-worktree number is a lie.
    let unpushed: Int

    var isClean: Bool { uncommitted == 0 && unpushed == 0 }
}

/// Lists, creates and removes the worktrees of a repo, under `~/.zenterm/worktrees/`.
///
/// Git is the whole registry. There is no index of our own to fall out of step, so a worktree made
/// by hand elsewhere is listed alongside ours and one deleted in Finder simply stops being listed.
///
/// Every call blocks on `git` or the filesystem, so callers run them off-main and hop back.
enum WorktreeStore {
    enum WorktreeError: Error, LocalizedError, Equatable {
        case notARepo(URL)
        case unbornHead(URL)
        case branchExists(String)
        case destinationExists(URL)
        case gitFailed(GitCommand.Failure)

        var errorDescription: String? {
            switch self {
            case .notARepo(let url):
                return "\(url.lastPathComponent) is not a git repository."
            case .unbornHead(let url):
                return "\(url.lastPathComponent) has no commits yet, so there is nothing to branch from."
            case .branchExists(let branch):
                return "A branch named \(branch) already exists."
            case .destinationExists(let url):
                return "\(url.lastPathComponent) is already a folder in the worktrees directory."
            case .gitFailed(let failure):
                return failure.errorDescription
            }
        }
    }

    #if DEBUG
        /// Test-only redirect, mirroring `ConfigLoader.defaultRootOverrideForTesting`.
        static var rootOverrideForTesting: URL?
    #endif

    /// Worktrees get a plain, typeable home of their own rather than a corner of app state: a
    /// worktree is a checkout the user opens a shell in.
    static var root: URL {
        #if DEBUG
            if let rootOverrideForTesting { return rootOverrideForTesting }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zenterm/worktrees", isDirectory: true)
    }

    // MARK: reading

    /// Every linked worktree of `repo`, wherever on disk it lives, main checkout excluded.
    ///
    /// Prunes first, so a worktree whose directory was deleted in Finder is forgotten here rather
    /// than lingering as a row that opens nothing.
    static func list(in repo: URL) throws -> [Worktree] {
        guard GitRepo.isGitRepo(repo) else { throw WorktreeError.notARepo(repo) }
        try git(["worktree", "prune"], in: repo)
        let listing = try git(["worktree", "list", "--porcelain"], in: repo)
        let main = try mainCheckout(of: repo)
        return parse(listing).filter { $0.path != main }
    }

    /// What removing the worktree would destroy, or nil when that cannot be determined.
    ///
    /// **Nil is not "clean".** Reporting zero when git failed would put "nothing uncommitted" in
    /// front of a person about to delete a tree we could not read.
    static func state(_ worktree: Worktree) -> WorktreeState? {
        guard let status = try? git(["status", "--porcelain"], in: worktree.path),
            let counted = try? git(
                ["rev-list", "--count", "HEAD", "--not", "--remotes"], in: worktree.path),
            let unpushed = Int(counted)
        else { return nil }
        return WorktreeState(uncommitted: lineCount(status), unpushed: unpushed)
    }

    // MARK: writing

    /// A worktree on a new `branch`, cut from the repo's default branch.
    static func create(branch: String, in repo: URL) throws -> Worktree {
        guard GitRepo.isGitRepo(repo) else { throw WorktreeError.notARepo(repo) }
        guard !branchExists(branch, in: repo) else { throw WorktreeError.branchExists(branch) }

        let base = try resolveBase(in: repo)
        let head = try git(["rev-parse", base], in: repo)
        let parent = root.appendingPathComponent(directoryName(for: repo), isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appendingPathComponent(slug(forText: branch), isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WorktreeError.destinationExists(destination)
        }

        do {
            try git(["worktree", "add", "-b", branch, destination.path, base], in: repo)
        } catch {
            // `worktree add` creates the branch before it checks the destination, so a failure
            // here leaves a branch behind with no tree on it unless we take it back.
            try? FileManager.default.removeItem(at: destination)
            if branchExists(branch, in: repo) { _ = try? git(["branch", "-D", branch], in: repo) }
            throw error
        }

        return Worktree(
            path: destination.standardizedFileURL, branch: branch, head: head, isLocked: false)
    }

    /// Delete the worktree, leaving the branch it held alone. `--force` is unconditional because
    /// carried files are always untracked and git refuses without it, so the confirm in front of
    /// this call is what makes it safe.
    static func remove(_ worktree: Worktree, in repo: URL) throws {
        try git(["worktree", "remove", "--force", worktree.path.path], in: repo)
    }

    // MARK: naming

    /// The directory holding one repo's worktrees, keyed on the repo **path** and carrying a digest
    /// of it, so two repos whose folders are both called `app` cannot share one.
    static func directoryName(for repo: URL) -> String {
        "\(slug(forText: repo.standardizedFileURL.lastPathComponent))-\(digest(of: repo))"
    }

    /// One path segment from free text, which may hold anything: a branch called `feature/x` names
    /// a directory called `feature-x`.
    static func slug(forText text: String) -> String {
        let kept = text.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character : "-"
        }
        let collapsed = String(kept).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "worktree" : collapsed.lowercased()
    }

    /// Eight hex characters of SHA-256 over the standardized path. Long enough that two repos on
    /// one machine will not collide, short enough to type.
    private static func digest(of path: URL) -> String {
        let data = Data(path.standardizedFileURL.path.utf8)
        return SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: helpers

    /// The repo's main checkout. `--git-common-dir` is the one answer that holds from inside any
    /// worktree, and `worktree list` sorts by path rather than putting the main one first.
    private static func mainCheckout(of repo: URL) throws -> URL {
        let common = try git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repo)
        return URL(fileURLWithPath: common).deletingLastPathComponent().standardizedFileURL
    }

    /// Records separated by a blank line, each a `key value` per line.
    private static func parse(_ listing: String) -> [Worktree] {
        listing.components(separatedBy: "\n\n").compactMap { record in
            var path: URL?
            var head: String?
            var branch: String?
            var locked = false
            for line in record.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard let key = parts.first else { continue }
                let value = parts.count > 1 ? String(parts[1]) : ""
                switch key {
                case "worktree": path = URL(fileURLWithPath: value).standardizedFileURL
                case "HEAD": head = value
                case "branch": branch = shortBranch(value)
                case "locked": locked = true
                // We pruned already, so anything still prunable is a locked worktree whose
                // directory is gone. There is nothing to open, and `bare` is not a checkout.
                case "prunable", "bare": return nil
                default: continue
                }
            }
            guard let path, let head else { return nil }
            return Worktree(path: path, branch: branch, head: head, isLocked: locked)
        }
    }

    private static func shortBranch(_ ref: String) -> String {
        ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }

    /// What a new worktree branches from: the remote's default branch where there is one, and the
    /// current checkout otherwise, so a repo with no remote still works.
    private static func resolveBase(in repo: URL) throws -> String {
        if let head = try? git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repo),
            !head.isEmpty
        {
            return head
        }
        if (try? git(["rev-parse", "--verify", "--quiet", "origin/main"], in: repo)) != nil {
            return "origin/main"
        }
        guard (try? git(["rev-parse", "--verify", "--quiet", "HEAD"], in: repo)) != nil else {
            throw WorktreeError.unbornHead(repo)
        }
        return "HEAD"
    }

    private static func branchExists(_ branch: String, in repo: URL) -> Bool {
        (try? git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repo)) != nil
    }

    private static func lineCount(_ output: String) -> Int {
        output.isEmpty ? 0 : output.split(separator: "\n").count
    }

    @discardableResult
    private static func git(_ args: [String], in dir: URL) throws -> String {
        switch GitCommand.run(args, in: dir) {
        case .success(let output): return output
        case .failure(let error):
            throw (error as? GitCommand.Failure).map(WorktreeError.gitFailed) ?? error
        }
    }
}
