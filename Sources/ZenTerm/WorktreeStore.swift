import CryptoKit
import Foundation

struct Worktree: Equatable {
    let path: URL
    let branch: String?
    let head: String
    let isLocked: Bool
}

struct WorktreeListing: Equatable {
    let commonDir: URL?
    let worktrees: [Worktree]
}

struct WorktreeState: Equatable {
    let files: [WorktreeFileChange]
    let lostCommits: Int

    var uncommitted: Int { files.count }
    var isClean: Bool { files.isEmpty && lostCommits == 0 }
}

/// Every call blocks on git, so callers run them off-main.
enum WorktreeStore {
    enum Base: Equatable {
        case defaultBranch
        case currentCheckout
    }

    enum Holder: Equatable {
        case mainCheckout(URL)
        case worktree(URL)
    }

    enum WorktreeError: Error, LocalizedError, Equatable {
        case notARepo(URL)
        case unbornHead(URL)
        case invalidBranchName(String)
        case branchExists(String)
        case branchNotThere(String)
        case branchInWorktree(String)
        case branchInMainCheckout(String, uncommitted: Int)
        case defaultBranchInWorktree(String, defaultBranch: String)
        case noFallbackBranch(String)
        case mainCheckoutOnDefaultBranch(String)
        case destinationExists(URL, branch: String?)
        case isLocked(URL)
        case gitFailed(GitCommand.Failure)
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
            case .branchNotThere(let branch):
                return "\(branch) is no longer a branch in this repository."
            case .branchInWorktree(let branch):
                return "\(branch) already has a worktree."
            case .branchInMainCheckout(let branch, let uncommitted):
                guard uncommitted > 0 else {
                    return "Your main checkout is on \(branch), and what it holds could not be read."
                }
                let files = "\(uncommitted) uncommitted file\(uncommitted == 1 ? "" : "s")"
                return "Your main checkout is on \(branch) and has \(files). Commit or stash them first."
            case .noFallbackBranch(let branch):
                return
                    "Your main checkout is on \(branch), and this repository has no default branch for it to move to."
            case .mainCheckoutOnDefaultBranch(let branch):
                return "Your main checkout is on \(branch), which is the default branch, so it cannot move off it."
            case .defaultBranchInWorktree(let branch, let base):
                return
                    "Your main checkout is on \(branch), and \(base) already has a worktree, so there is nowhere to move it."
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
        static var rootOverrideForTesting: URL?

        static var beforeClaimingForTesting: ((URL) -> Void)?
    #endif

    static var root: URL {
        #if DEBUG
            if let rootOverrideForTesting { return rootOverrideForTesting }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zenterm/worktrees", isDirectory: true)
    }

    /// The picker passes `pruning: false`: a prune is final, and a moved worktree loses `git worktree repair`.
    static func list(in repo: URL, pruning: Bool = true) throws -> [Worktree] {
        guard GitRepo.isGitRepo(repo) else { throw WorktreeError.notARepo(repo) }
        let listing = try porcelain(in: repo)
        if pruning, shouldPrune(listing) { _ = try? git(["worktree", "prune"], in: repo) }
        let main = mainPath(in: listing)
        return parse(listing).filter { $0.path != main }
    }

    /// Nil when git fails, never a zero that would read as clean.
    static func state(_ worktree: Worktree) -> WorktreeState? {
        state(at: worktree.path, countingLostCommits: true)
    }

    static func state(at checkout: URL, countingLostCommits: Bool = false) -> WorktreeState? {
        guard let status = try? git(untrackedStatus, in: checkout) else { return nil }
        let files = WorktreeFileChange.parse(status)
        guard countingLostCommits else { return WorktreeState(files: files, lostCommits: 0) }
        guard let listing = try? porcelain(in: checkout),
            let counted = try? git(
                ["rev-list", "--count", "HEAD", "--not", "--glob=refs/*"] + heads(in: listing, besides: checkout),
                in: checkout),
            let commits = Int(counted)
        else { return nil }
        return WorktreeState(files: files, lostCommits: commits)
    }

    private static func heads(in listing: String, besides checkout: URL) -> [String] {
        let own = checkout.resolvingSymlinksInPath().standardizedFileURL
        return parse(listing)
            .filter { $0.path.resolvingSymlinksInPath().standardizedFileURL != own && !$0.head.isEmpty }
            .map(\.head)
    }

    private static let untrackedStatus = ["status", "--porcelain=v2", "--untracked-files=all", "-z"]

    static func commonDir(of repo: URL) -> URL? {
        guard let answer = try? git(["rev-parse", "--git-common-dir"], in: repo), !answer.isEmpty
        else { return nil }
        let url = answer.hasPrefix("/") ? URL(fileURLWithPath: answer) : repo.appendingPathComponent(answer)
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    struct CreateOptions: Equatable {
        let branches: Set<String>
        let defaultBase: String?
        let currentBranch: String?
        let holders: [String: Holder]
    }

    static func createOptions(in repo: URL) -> CreateOptions {
        CreateOptions(
            branches: branchNames(in: repo), defaultBase: defaultBaseName(in: repo),
            currentBranch: GitRepo.currentBranch(repo), holders: holders(in: repo))
    }

    static func holders(in repo: URL) -> [String: Holder] {
        guard let listing = try? porcelain(in: repo) else { return [:] }
        let main = mainPath(in: listing)
        var holders: [String: Holder] = [:]
        for worktree in parse(listing) {
            guard let branch = worktree.branch else { continue }
            holders[branch] = worktree.path == main ? .mainCheckout(worktree.path) : .worktree(worktree.path)
        }
        return holders
    }

    static func holder(of branch: String, in repo: URL) -> Holder? { holders(in: repo)[branch] }

    static func branchNames(in repo: URL) -> Set<String> {
        guard
            let output = try? git(
                ["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repo)
        else { return [] }
        return Set(output.split(separator: "\n").map(String.init))
    }

    private static func defaultBaseName(in repo: URL) -> String? {
        guard let base = try? resolveBase(.defaultBranch, in: repo) else { return nil }
        return base == "HEAD" ? GitRepo.currentBranch(repo) : base
    }

    static func create(branch: String, base: Base = .defaultBranch, in repo: URL) throws -> Worktree {
        guard GitRepo.isGitRepo(repo) else { throw WorktreeError.notARepo(repo) }
        guard isUsableBranchName(branch, in: repo) else { throw WorktreeError.invalidBranchName(branch) }

        let baseRef = try resolveBase(base, in: repo)
        let base0ID = try git(["rev-parse", baseRef], in: repo)

        #if DEBUG
            beforeClaimingForTesting?(repo)
        #endif

        try claimBranch(branch, at: baseRef, in: repo)
        return try addWorktree(
            branch, claim: BranchClaim(name: branch, oid: base0ID), fallbackHead: base0ID, in: repo)
    }

    static func create(existingBranch branch: String, in repo: URL) throws -> Worktree {
        guard GitRepo.isGitRepo(repo) else { throw WorktreeError.notARepo(repo) }
        guard isUsableBranchName(branch, in: repo) else { throw WorktreeError.invalidBranchName(branch) }
        guard branchExists(branch, in: repo) else { throw WorktreeError.branchNotThere(branch) }

        var move: CheckoutMove?
        switch holder(of: branch, in: repo) {
        case .worktree:
            throw WorktreeError.branchInWorktree(branch)
        case .mainCheckout(let main):
            let uncommitted = state(at: main)?.uncommitted
            guard uncommitted == 0 else {
                throw WorktreeError.branchInMainCheckout(branch, uncommitted: uncommitted ?? 0)
            }
            guard let fallback = fallbackBranch(in: repo) else {
                throw WorktreeError.noFallbackBranch(branch)
            }
            guard fallback != branch else { throw WorktreeError.mainCheckoutOnDefaultBranch(branch) }
            if case .worktree = holder(of: fallback, in: repo) {
                throw WorktreeError.defaultBranchInWorktree(branch, defaultBranch: fallback)
            }
            move = CheckoutMove(checkout: main, from: branch, to: fallback)
        case nil:
            break
        }

        let head = (try? git(["rev-parse", "refs/heads/\(branch)"], in: repo)) ?? ""

        #if DEBUG
            beforeClaimingForTesting?(repo)
        #endif

        return try addWorktree(branch, claim: nil, fallbackHead: head, in: repo, move: move)
    }

    private struct BranchClaim {
        let name: String
        let oid: String
    }

    private static func addWorktree(
        _ branch: String, claim: BranchClaim?, fallbackHead: String, in repo: URL,
        move: CheckoutMove? = nil
    ) throws -> Worktree {
        let parent = root.appendingPathComponent(
            directoryName(for: mainCheckout(of: repo)), isDirectory: true)
        let destination = parent.appendingPathComponent(slug(forText: branch), isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try claimDestination(destination, in: repo)
        } catch {
            throw takingBack(claim, at: nil, in: repo, after: error)
        }

        do {
            if let move { try git(["checkout", move.to], in: move.checkout) }
            try git(["worktree", "add", destination.path, branch], in: repo)
        } catch {
            throw takingBack(claim, at: destination, undoing: move, in: repo, after: error)
        }

        let head = (try? git(["rev-parse", "HEAD"], in: destination)) ?? fallbackHead
        return Worktree(
            path: destination.standardizedFileURL, branch: branch, head: head, isLocked: false)
    }

    private static func fallbackBranch(in repo: URL) -> String? {
        guard let base = try? resolveBase(.defaultBranch, in: repo) else { return nil }
        let local = base.hasPrefix("origin/") ? String(base.dropFirst("origin/".count)) : base
        guard local != "HEAD", branchExists(local, in: repo) else { return nil }
        return local
    }

    /// `--no-track`: an upstream named differently makes `push.default=simple` refuse the first push.
    private static func claimBranch(_ branch: String, at baseRef: String, in repo: URL) throws {
        do {
            try git(["branch", "--no-track", "--", branch, baseRef], in: repo)
        } catch {
            throw branchExists(branch, in: repo) ? WorktreeError.branchExists(branch) : error
        }
    }

    private static func claimDestination(_ destination: URL, in repo: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: false)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw WorktreeError.destinationExists(
                destination, branch: branchHolding(destination, in: repo))
        }
    }

    private struct CheckoutMove {
        let checkout: URL
        let from: String
        let to: String
    }

    private static func takingBack(
        _ claim: BranchClaim?, at destination: URL?, undoing move: CheckoutMove? = nil,
        in repo: URL, after cause: Error
    ) -> Error {
        var leftBehind = rollback(claim, at: destination, in: repo)
        if let move, (try? git(["checkout", move.from], in: move.checkout)) == nil {
            leftBehind.append("your main checkout on \(move.to)")
        }
        guard leftBehind.isEmpty else {
            return WorktreeError.rollbackIncomplete(
                cause: cause.localizedDescription, leftBehind: leftBehind)
        }
        return cause
    }

    /// Unregisters the worktree first: git won't delete a branch still registered to one.
    private static func rollback(_ claim: BranchClaim?, at destination: URL?, in repo: URL) -> [String] {
        var leftBehind: [String] = []
        if let destination {
            _ = try? git(["worktree", "remove", "--force", destination.path], in: repo)
            try? FileManager.default.removeItem(at: destination)
            _ = try? git(["worktree", "prune"], in: repo)
            if FileManager.default.fileExists(atPath: destination.path) {
                leftBehind.append("the folder \(destination.lastPathComponent)")
            }
        }
        guard let claim, branchExists(claim.name, in: repo) else { return leftBehind }

        let unmoved =
            (try? git(["rev-parse", "--verify", "refs/heads/\(claim.name)"], in: repo))
            == claim.oid
        if unmoved, (try? git(["branch", "-D", "--", claim.name], in: repo)) != nil { return leftBehind }
        leftBehind.append("the branch \(claim.name)")
        return leftBehind
    }

    /// `--force` always: carried files are untracked and git refuses them without it.
    static func remove(_ worktree: Worktree, in repo: URL) throws {
        guard !worktree.isLocked else { throw WorktreeError.isLocked(worktree.path) }
        try git(["worktree", "remove", "--force", worktree.path.path], in: repo)
    }

    static func directoryName(for repo: URL) -> String {
        "\(slug(forText: repo.standardizedFileURL.lastPathComponent))-\(digest(of: repo))"
    }

    static func slug(forText text: String) -> String {
        let kept = text.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character : "-"
        }
        let collapsed = String(kept).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "worktree" : collapsed.lowercased()
    }

    private static func digest(of path: URL) -> String {
        let data = Data(path.standardizedFileURL.path.utf8)
        return SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Refuses when a prunable path is on an unmounted volume: `worktree repair` can't undo a prune.
    static func shouldPrune(_ listing: String) -> Bool {
        let prunable = prunablePaths(in: listing)
        return !prunable.isEmpty && prunable.allSatisfy(isOnAPresentVolume)
    }

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

    /// Git's first record, since a submodule's common dir sits inside `.git/modules`, not a checkout.
    private static func mainCheckout(of repo: URL) -> URL {
        return (try? porcelain(in: repo)).flatMap(mainPath(in:)) ?? repo.standardizedFileURL
    }

    private static func mainPath(in listing: String) -> URL? {
        records(in: listing).first.flatMap(worktreePath(in:))
    }

    private static func branchHolding(_ destination: URL, in repo: URL) -> String? {
        guard let listing = try? porcelain(in: repo) else { return nil }
        return parse(listing).first { $0.path == destination.standardizedFileURL }?.branch
    }

    /// `-z`: git escapes a lock reason but never the path, so a newline would split a record.
    private static func porcelain(in repo: URL) throws -> String {
        try git(["worktree", "list", "--porcelain", "-z"], in: repo)
    }

    private static func records(in listing: String) -> [[Substring]] {
        listing.components(separatedBy: "\0\0").map { $0.split(separator: "\0") }
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

    /// Verifies `origin/HEAD`'s target: `symbolic-ref` succeeds even when that remote branch is gone.
    private static func resolveBase(_ base: Base, in repo: URL) throws -> String {
        guard base == .defaultBranch else { return try verifiedHead(in: repo) }
        if let head = try? git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repo),
            !head.isEmpty,
            (try? git(["rev-parse", "--verify", "--quiet", "\(head)^{commit}"], in: repo)) != nil
        {
            return head
        }
        if (try? git(["rev-parse", "--verify", "--quiet", "origin/main"], in: repo)) != nil {
            return "origin/main"
        }
        return try verifiedHead(in: repo)
    }

    private static func verifiedHead(in repo: URL) throws -> String {
        guard (try? git(["rev-parse", "--verify", "--quiet", "HEAD"], in: repo)) != nil else {
            throw WorktreeError.unbornHead(repo)
        }
        return "HEAD"
    }

    /// Rejects a leading dash: `refs/heads/-m` is valid, and `worktree add -b -m` renames the current branch.
    private static func isUsableBranchName(_ branch: String, in repo: URL) -> Bool {
        guard !branch.isEmpty, !branch.hasPrefix("-") else { return false }
        return (try? git(["check-ref-format", "refs/heads/\(branch)"], in: repo)) != nil
    }

    private static func branchExists(_ branch: String, in repo: URL) -> Bool {
        (try? git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repo)) != nil
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
