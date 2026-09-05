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
    /// Commits on this worktree's HEAD that no remote has, and zero in a repo with no remote at
    /// all: `remove` leaves the branch alone, so with nowhere to push there is nothing to lose.
    /// There is no stash count beside it: `refs/stash` is shared across every worktree of a repo.
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
        case invalidBranchName(String)
        case branchExists(String)
        /// `branch` names the worktree already holding the folder, when one does. Two branch names
        /// can slug onto one folder, so the folder's own name is not what the user typed.
        case destinationExists(URL, branch: String?)
        case isLocked(URL)
        case gitFailed(GitCommand.Failure)
        /// The create failed *and* undoing it did not finish. `leftBehind` names what survives.
        case rollbackIncomplete(cause: String, leftBehind: [String])

        var errorDescription: String? {
            switch self {
            case .notARepo(let url):
                return "\(url.lastPathComponent) is not a git repository."
            case .unbornHead(let url):
                return "\(url.lastPathComponent) has no commits yet, so there is nothing to branch from."
            case .invalidBranchName(let branch):
                return "\(branch) is not a branch name git will take."
            case .branchExists(let branch):
                return "A branch named \(branch) already exists."
            case .destinationExists(let url, let branch):
                guard let branch else {
                    return "\(url.lastPathComponent) is already a folder in the worktrees directory."
                }
                return "A worktree for \(branch) already uses that folder name."
            case .isLocked(let url):
                return "\(url.lastPathComponent) is locked. Unlock it before removing it."
            case .gitFailed(let failure):
                return failure.errorDescription
            case .rollbackIncomplete(let cause, let leftBehind):
                return "\(cause) Cleaning up left \(sentenceList(leftBehind)) behind."
            }
        }

        private func sentenceList(_ items: [String]) -> String {
            guard let last = items.last else { return "nothing" }
            guard items.count > 1 else { return last }
            return items.dropLast().joined(separator: ", ") + " and " + last
        }
    }

    #if DEBUG
        /// Test-only redirect, mirroring `ConfigLoader.defaultRootOverrideForTesting`.
        static var rootOverrideForTesting: URL?

        /// Test-only seam for the window between the branch precheck and `worktree add`, the only
        /// place a branch we did not create can appear. Mirrors `CloneStore.willRemoveForTesting`.
        static var betweenCheckAndAddForTesting: ((URL) -> Void)?
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
    /// A worktree whose directory is gone is dropped from the answer either way, because git marks
    /// it prunable on its own. The prune is hygiene for git's own commands, and it is conditional.
    static func list(in repo: URL) throws -> [Worktree] {
        guard GitRepo.isGitRepo(repo) else { throw WorktreeError.notARepo(repo) }
        let listing = try git(["worktree", "list", "--porcelain"], in: repo)
        if isSafeToPrune(listing) { _ = try? git(["worktree", "prune"], in: repo) }
        let main = mainPath(in: listing)
        return parse(listing).filter { $0.path != main }
    }

    /// What removing the worktree would destroy, or nil when that cannot be determined.
    ///
    /// **Nil is not "clean".** Reporting zero when git failed would put "nothing uncommitted" in
    /// front of a person about to delete a tree we could not read.
    static func state(_ worktree: Worktree) -> WorktreeState? {
        guard let status = try? git(["status", "--porcelain"], in: worktree.path),
            let remotes = try? git(["remote"], in: worktree.path)
        else { return nil }
        // `--not --remotes` excludes nothing when there are no remote-tracking refs, so the count
        // would be the repo's whole history rather than the work a push would carry off.
        guard !remotes.isEmpty else {
            return WorktreeState(uncommitted: lineCount(status), unpushed: 0)
        }
        guard
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
        guard isUsableBranchName(branch, in: repo) else { throw WorktreeError.invalidBranchName(branch) }
        guard !branchExists(branch, in: repo) else { throw WorktreeError.branchExists(branch) }

        let base = try resolveBase(in: repo)
        let base0ID = try git(["rev-parse", base], in: repo)
        // Keyed on the main checkout, never on `repo`: creating from inside a worktree would
        // otherwise give the same repo a second home under the root.
        let parent = root.appendingPathComponent(
            directoryName(for: mainCheckout(of: repo)), isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appendingPathComponent(slug(forText: branch), isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WorktreeError.destinationExists(
                destination, branch: branchHolding(destination, in: repo))
        }

        #if DEBUG
            betweenCheckAndAddForTesting?(repo)
        #endif

        do {
            try git(["worktree", "add", "-b", branch, destination.path, base], in: repo)
        } catch {
            let leftBehind = rollback(branch: branch, at: destination, createdAt: base0ID, in: repo)
            guard leftBehind.isEmpty else {
                throw WorktreeError.rollbackIncomplete(
                    cause: error.localizedDescription, leftBehind: leftBehind)
            }
            throw error
        }

        // Read the worktree's own HEAD rather than trusting the OID resolved before the add: a
        // concurrent fetch can move `base` in between, and a reported sha has to be the real one.
        let head = (try? git(["rev-parse", "HEAD"], in: destination)) ?? base0ID
        return Worktree(
            path: destination.standardizedFileURL, branch: branch, head: head, isLocked: false)
    }

    /// Undo what a failed `create` made, and report what it could not take back.
    ///
    /// Order matters: git refuses to delete a branch still registered to a worktree, even one whose
    /// directory is gone, so the registration goes first and a bare `removeItem` never leads.
    private static func rollback(
        branch: String, at destination: URL, createdAt base0ID: String, in repo: URL
    ) -> [String] {
        _ = try? git(["worktree", "remove", "--force", destination.path], in: repo)
        try? FileManager.default.removeItem(at: destination)
        _ = try? git(["worktree", "prune"], in: repo)

        var leftBehind: [String] = []
        if FileManager.default.fileExists(atPath: destination.path) {
            leftBehind.append("the folder \(destination.lastPathComponent)")
        }
        guard branchExists(branch, in: repo) else { return leftBehind }

        // Delete only a branch still standing where we put it: one that moved belongs to whoever
        // created it after our precheck. `-D` because that OID check is the merge check, and
        // `-d`'s is against the *current* HEAD, which `base` is routinely ahead of.
        let atBase = (try? git(["rev-parse", "--verify", "refs/heads/\(branch)"], in: repo)) == base0ID
        if atBase, (try? git(["branch", "-D", "--", branch], in: repo)) != nil { return leftBehind }
        leftBehind.append("the branch \(branch)")
        return leftBehind
    }

    /// Delete the worktree, leaving the branch it held alone. `--force` is unconditional because
    /// carried files are always untracked and git refuses without it, so the confirm in front of
    /// this call is what makes it safe. A lock is the user's own "not this one" and is obeyed.
    static func remove(_ worktree: Worktree, in repo: URL) throws {
        guard !worktree.isLocked else { throw WorktreeError.isLocked(worktree.path) }
        try git(["worktree", "remove", "--force", worktree.path.path], in: repo)
    }

    // MARK: naming

    /// The directory holding one repo's worktrees, keyed on the repo **path** and carrying a digest
    /// of it, so two repos whose folders are both called `app` cannot share one.
    static func directoryName(for repo: URL) -> String {
        "\(slug(forText: repo.standardizedFileURL.lastPathComponent))-\(digest(of: repo))"
    }

    /// One path segment from free text, which may hold anything: a branch called `feature/x` names
    /// a directory called `feature-x`. Lossy, so two branch names can arrive at one folder.
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

    /// Whether pruning now would only forget directories that are genuinely gone.
    ///
    /// A worktree on an unmounted volume is indistinguishable from a deleted one, and pruning it is
    /// final: `worktree repair` cannot rebuild an admin file that no longer exists.
    static func isSafeToPrune(_ listing: String) -> Bool {
        prunablePaths(in: listing).allSatisfy(isOnAPresentVolume)
    }

    /// Volumes other than the boot one live under `/Volumes`, and the mount point goes with the
    /// drive, so an absent one reads as "cannot see it" rather than "deleted".
    private static func isOnAPresentVolume(_ path: URL) -> Bool {
        let parts = path.standardizedFileURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return true }
        return FileManager.default.fileExists(atPath: "/Volumes/\(parts[2])")
    }

    private static func prunablePaths(in listing: String) -> [URL] {
        records(in: listing)
            .filter { $0.contains { $0.hasPrefix("prunable") } }
            .compactMap(worktreePath(in:))
    }

    /// The repo's main checkout. `worktree list` documents it as record one, and taking git's own
    /// path keeps a submodule right: there `--git-common-dir` names `.git/modules/<name>`, whose
    /// parent is an internals directory rather than any checkout.
    private static func mainCheckout(of repo: URL) -> URL {
        let listing = try? git(["worktree", "list", "--porcelain"], in: repo)
        return listing.flatMap(mainPath(in:)) ?? repo.standardizedFileURL
    }

    private static func mainPath(in listing: String) -> URL? {
        records(in: listing).first.flatMap(worktreePath(in:))
    }

    /// Which branch already holds `destination`, when a worktree holds it at all rather than some
    /// stray folder. Read without pruning: this runs on the way out of a failed create.
    private static func branchHolding(_ destination: URL, in repo: URL) -> String? {
        guard let listing = try? git(["worktree", "list", "--porcelain"], in: repo) else { return nil }
        return parse(listing).first { $0.path == destination.standardizedFileURL }?.branch
    }

    /// Records separated by a blank line, each a `key value` per line.
    private static func records(in listing: String) -> [[Substring]] {
        listing.components(separatedBy: "\n\n").map { $0.split(separator: "\n") }
    }

    private static func worktreePath(in record: [Substring]) -> URL? {
        record.first { $0.hasPrefix("worktree ") }
            .map { URL(fileURLWithPath: String($0.dropFirst("worktree ".count))).standardizedFileURL }
    }

    private static func parse(_ listing: String) -> [Worktree] {
        records(in: listing).compactMap { record in
            var path: URL?
            var head: String?
            var branch: String?
            var locked = false
            for line in record {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard let key = parts.first else { continue }
                let value = parts.count > 1 ? String(parts[1]) : ""
                switch key {
                case "worktree": path = URL(fileURLWithPath: value).standardizedFileURL
                case "HEAD": head = value
                case "branch": branch = shortBranch(value)
                case "locked": locked = true
                // A prunable record's directory is gone, so there is nothing to open whether or not
                // the prune that follows takes it. `bare` is not a checkout either.
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

    /// A name git will take that cannot also be read as a command-line option.
    ///
    /// The dash check is the load-bearing half. `refs/heads/-m` is a perfectly *valid* ref name, so
    /// `check-ref-format` passes it, and `worktree add -b -m` then reaches git's own unguarded
    /// `git branch` call and renames whatever branch the repo is standing on.
    private static func isUsableBranchName(_ branch: String, in repo: URL) -> Bool {
        guard !branch.isEmpty, !branch.hasPrefix("-") else { return false }
        return (try? git(["check-ref-format", "refs/heads/\(branch)"], in: repo)) != nil
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
