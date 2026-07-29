import Foundation

/// Runs `git` off the main thread and delivers a parsed status back on main. The app's first real
/// subprocess: everything git-facing for the diff viewer lives here, so the chrome only ever sees
/// `[FileDiff]`. Never blocks the main thread (ZEN-90): the work runs on a global queue and hops
/// back via `DispatchQueue.main.async`.
final class GitDiffRunner {
    /// The repo root the diff is computed from, resolved by the caller via `GitRepo.repoRoot(for:)`.
    /// All git invocations run with this as their working directory.
    let repoRoot: URL

    init(repoRoot: URL) {
        self.repoRoot = repoRoot
    }

    /// A full status: the three diff slices the viewer stacks. `baseBranch`/`baseSHA` describe the
    /// fork point the committed slice is measured from (nil when no base could be resolved).
    /// `currentBranch` is the checked-out branch (nil when detached), for the viewer's footer.
    struct StatusLoad: Equatable {
        let unstaged: [FileDiff]
        let staged: [FileDiff]
        let committed: [FileDiff]
        let baseBranch: String?
        let baseSHA: String?
        let currentBranch: String?

        var isEmpty: Bool { unstaged.isEmpty && staged.isEmpty && committed.isEmpty }

        func files(for scope: DiffScope) -> [FileDiff] {
            switch scope {
            case .unstaged: return unstaged
            case .staged: return staged
            case .committed: return committed
            }
        }
    }

    /// Why a load produced nothing usable. `.gitUnavailable` means git itself couldn't run;
    /// `.gitError` carries git's stderr for the failing command.
    enum Failure: Error, Equatable {
        case gitUnavailable
        case gitError(String)
    }

    /// Loads the repo's status off-main and calls `completion` on the main thread. `base` names the
    /// ref the committed slice forks from; nil uses the repo's default branch. A prior call is not
    /// cancelled; the caller drives one load at a time.
    func loadStatus(
        base: String? = nil, head: String? = nil,
        completion: @escaping (Result<StatusLoad, Failure>) -> Void
    ) {
        let repoRoot = self.repoRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<StatusLoad, Failure>
            do {
                result = .success(try Self.loadSync(base: base, head: head, repoRoot: repoRoot))
            } catch let failure as Failure {
                result = .failure(failure)
            } catch {
                result = .failure(.gitError(String(describing: error)))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Loads the repo's local branches off-main and calls `completion` on the main thread with the
    /// default branch pinned first, then the rest by most-recent commit — the order the base picker
    /// shows. A git failure yields an empty list (the picker just shows nothing rather than an error;
    /// the current base is unaffected).
    func loadBranches(completion: @escaping ([String]) -> Void) {
        let repoRoot = self.repoRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let recency =
                (try? Self.runGit(
                    ["for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/heads"],
                    in: repoRoot))?
                .split(separator: "\n").map(String.init) ?? []
            let preferred = try? Self.resolveDefaultBase(in: repoRoot)
            let ordered = Self.orderedBranches(recency: recency, default: preferred)
            DispatchQueue.main.async { completion(ordered) }
        }
    }

    /// Loads the branches the viewer can be pointed at, each tagged with its worktree if it has one,
    /// checked-out branch first (ZEN-313). Separate from `loadBranches` because the two pickers want
    /// opposite things: the base picker hides the current branch, the head picker leads with it.
    /// A git failure yields an empty list, leaving the picker empty rather than failing the load.
    func loadHeads(completion: @escaping ([BranchOption]) -> Void) {
        let repoRoot = self.repoRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let recency =
                (try? Self.runGit(
                    ["for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/heads"],
                    in: repoRoot))?
                .split(separator: "\n").map(String.init) ?? []
            let porcelain = (try? Self.runGit(["worktree", "list", "--porcelain"], in: repoRoot)) ?? ""
            let current = (try? Self.runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ordered = Self.orderedHeads(
                recency: recency,
                current: (current == "HEAD" || current?.isEmpty == true) ? nil : current,
                worktrees: Self.worktrees(fromPorcelain: porcelain))
            DispatchQueue.main.async { completion(ordered) }
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// The base dropdown's branch order: the default branch first (so `main` sits on top even when it
    /// hasn't been committed to recently), then every other branch by the recency order git returned,
    /// deduplicated. A `default` not among the local branches is still pinned first, since it may be a
    /// remote default the user forks from without a local branch.
    ///
    /// **Nothing is excluded here.** This used to drop the checked-out branch, on the grounds that
    /// comparing committed work against the branch it is on is meaningless. That is still true, but it
    /// is no longer the checkout that decides it: once the reader can pick a head (ZEN-313), the branch
    /// to keep out of the base list is whichever head is *selected*, which this layer does not know.
    /// `DiffViewerOverlay` owns both selections and does the excluding on both sides.
    static func orderedBranches(recency: [String], default preferred: String?) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        func add(_ name: String) {
            guard !name.isEmpty, seen.insert(name).inserted else { return }
            ordered.append(name)
        }
        if let preferred, !preferred.isEmpty { add(preferred) }
        recency.forEach(add)
        return ordered
    }

    /// The `git diff` argument list for a slice. `--no-color`/`--no-ext-diff` keep the output a plain
    /// unified diff the parser can read regardless of git config; `--find-renames` makes a moved file
    /// read as a rename rather than an add plus a delete. Unstaged is working-tree vs index; staged is
    /// index vs HEAD (`--cached`); committed is the fork point (`mergeBase`) vs `head`.
    ///
    /// `head` is `HEAD` for the checkout being read, or a branch name when the reader picked a branch
    /// that has no worktree of its own (ZEN-313). Only the committed slice can honour it: unstaged and
    /// staged are working-tree state, which exists only where a branch is actually checked out.
    static func diffArguments(scope: DiffScope, mergeBase: String, head: String = "HEAD") -> [String] {
        let base = ["diff", "--no-color", "--no-ext-diff", "--find-renames"]
        switch scope {
        case .unstaged: return base
        case .staged: return base + ["--cached"]
        case .committed: return base + [mergeBase, head]
        }
    }

    /// A branch the reader can point the viewer at, and whether it has a worktree on disk.
    ///
    /// The distinction decides what the viewer can show. A branch with a worktree has a real working
    /// tree, so all three slices are live once the runner is pointed at that path. A branch without
    /// one exists only as commits, so only the committed slice means anything.
    struct BranchOption: Equatable {
        let name: String
        let worktree: URL?
        /// The branch checked out in the repo the viewer opened on. It is the default head, and the
        /// one whose worktree is the repo root itself.
        let isCurrent: Bool

        var hasWorktree: Bool { worktree != nil }
    }

    /// Branch-to-worktree pairs from `git worktree list --porcelain`. Records are blank-line separated
    /// and each carries `worktree <path>` plus either `branch refs/heads/<name>` or `detached`. A
    /// detached worktree is skipped: there is no branch name to offer for it.
    ///
    /// Pure, so the parse is unit-testable without laying down real worktrees on disk.
    static func worktrees(fromPorcelain text: String) -> [String: URL] {
        var result: [String: URL] = [:]
        for record in text.components(separatedBy: "\n\n") {
            var path: URL?
            var branch: String?
            for line in record.split(separator: "\n") {
                if line.hasPrefix("worktree ") {
                    path = URL(fileURLWithPath: String(line.dropFirst("worktree ".count)))
                } else if line.hasPrefix("branch refs/heads/") {
                    branch = String(line.dropFirst("branch refs/heads/".count))
                }
            }
            if let path, let branch, !branch.isEmpty { result[branch] = path }
        }
        return result
    }

    /// The head picker's branch order: the checked-out branch first (it is what the viewer opens on),
    /// then the rest by the recency order git returned, deduplicated.
    ///
    /// The mirror of `orderedBranches`, and deliberately not the same function: the base picker
    /// *excludes* the current branch, because comparing committed work against the branch it is on is
    /// meaningless. The head picker must include it, because it is the default.
    static func orderedHeads(recency: [String], current: String?, worktrees: [String: URL])
        -> [BranchOption]
    {
        var seen = Set<String>()
        var ordered: [BranchOption] = []
        func add(_ name: String) {
            guard !name.isEmpty, seen.insert(name).inserted else { return }
            ordered.append(
                BranchOption(name: name, worktree: worktrees[name], isCurrent: name == current))
        }
        if let current { add(current) }
        recency.forEach(add)
        return ordered
    }

    /// The branch name from a ref, e.g. `origin/release/1.x` -> `release/1.x`. Strips only the leading
    /// `origin/`, so a branch name with slashes survives. Nil when the ref is blank.
    static func defaultBranchName(fromSymbolicRef ref: String) -> String? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prefix = "origin/"
        return trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
    }

    /// Untracked files rendered as synthetic all-added `FileDiff`s, since `git diff` never shows them.
    /// They belong to the unstaged slice (working-tree files not yet in the index).
    static func syntheticUntrackedDiffs(untrackedFiles: [(path: String, contents: String)]) -> [FileDiff] {
        untrackedFiles.map { syntheticAddedDiff(path: $0.path, contents: $0.contents) }
    }

    private static func syntheticAddedDiff(path: String, contents: String) -> FileDiff {
        var lines = contents.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }  // a trailing newline is a terminator, not a line
        let diffLines = lines.enumerated().map { index, text in
            DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: index + 1, text: text)
        }
        let hunks =
            diffLines.isEmpty
            ? []
            : [Hunk(header: "@@ -0,0 +1,\(diffLines.count) @@", oldStart: 0, newStart: 1, lines: diffLines)]
        return FileDiff(path: path, oldPath: nil, changeKind: .added, hunks: hunks)
    }

    // MARK: - Off-main worker

    /// Runs synchronously on a background queue: the three diff slices, the fork base for the
    /// committed slice, and the untracked fold into unstaged. Throws `Failure` on any git failure.
    private static func loadSync(base: String?, head: String?, repoRoot: URL) throws -> StatusLoad {
        // A picked branch with no worktree has no working tree to read, so the two working-tree slices
        // are empty by definition rather than by failure (ZEN-313). Reading them anyway would show the
        // *checkout's* uncommitted work under a heading naming someone else's branch, which is worse
        // than showing nothing: it would look like that branch had those edits.
        let readsWorkingTree = head == nil
        let unstagedPatch =
            readsWorkingTree
            ? try runGit(diffArguments(scope: .unstaged, mergeBase: ""), in: repoRoot) : ""
        let stagedPatch =
            readsWorkingTree
            ? try runGit(diffArguments(scope: .staged, mergeBase: ""), in: repoRoot) : ""

        // The committed slice degrades gracefully: a base that can't be resolved (no default, unrelated
        // histories so `merge-base` fails, or a picked branch deleted since the picker loaded) leaves the
        // committed section empty rather than failing the whole load — the unstaged/staged diffs above are
        // already fetched, and losing them to an unrelated committed-slice error would be the worse bug.
        var baseBranch: String?
        var baseSHA: String?
        var committedBase: String?  // full merge-base SHA, for the committed slice's old-side blob fetch
        var committedPatch = ""
        let headRef = head ?? "HEAD"
        if let resolved = base ?? (try? resolveDefaultBase(in: repoRoot)) {
            let ref = existingRef(for: resolved, in: repoRoot)
            if let mergeBase = (try? runGit(["merge-base", ref, headRef], in: repoRoot))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !mergeBase.isEmpty,
                let patch = try? runGit(
                    diffArguments(scope: .committed, mergeBase: mergeBase, head: headRef), in: repoRoot)
            {
                baseBranch = defaultBranchName(fromSymbolicRef: resolved)
                baseSHA = String(mergeBase.prefix(7))
                committedBase = mergeBase
                committedPatch = patch
            }
        }

        // The branch the viewer is showing, for the footer. A picked head names itself; otherwise it is
        // the checked-out branch. `--abbrev-ref HEAD` yields the literal "HEAD" when detached, which
        // isn't a branch name — treat that as none.
        let checkedOut = (try? runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCheckout =
            (checkedOut == nil || checkedOut == "HEAD" || checkedOut?.isEmpty == true) ? nil : checkedOut
        let currentBranch = head ?? resolvedCheckout

        var unstaged = DiffParser.parse(unstagedPatch)
        if readsWorkingTree {
            unstaged += syntheticUntrackedDiffs(untrackedFiles: readUntracked(repoRoot: repoRoot))
        }
        return StatusLoad(
            unstaged: stamp(unstaged, scope: .unstaged, baseSHA: nil),
            staged: stamp(DiffParser.parse(stagedPatch), scope: .staged, baseSHA: nil),
            committed: stamp(
                DiffParser.parse(committedPatch), scope: .committed, baseSHA: committedBase,
                headRef: head),
            baseBranch: baseBranch,
            baseSHA: baseSHA,
            currentBranch: currentBranch)
    }

    /// Stamp a parsed slice with the scope it came from and (for committed) the refs each side's
    /// whole-file blob is fetched from, so the syntax highlighter reads the right content (ZEN-239,
    /// and `headRef` for ZEN-313's picked branch).
    private static func stamp(
        _ diffs: [FileDiff], scope: DiffScope, baseSHA: String?, headRef: String? = nil
    ) -> [FileDiff] {
        diffs.map {
            var diff = $0
            diff.scope = scope
            diff.baseSHA = baseSHA
            diff.headRef = headRef
            return diff
        }
    }

    /// One side of a file's diff: the pre-change (`old`) or post-change (`new`) revision.
    enum Side { case old, new }

    /// Where one side's whole-file blob comes from: a `git show` invocation, or the working-tree file.
    enum BlobSource: Equatable {
        case git([String])
        case workingTree(path: String)
    }

    /// The source for one side of `file`'s blob, by scope: unstaged is index-vs-working-tree, staged is
    /// HEAD-vs-index, committed is base-vs-HEAD. nil when there's no ref (a committed slice with no base).
    /// Pure, so the ref selection is unit-testable without a repo. A rename's old content lives at the old
    /// path; the new side is always the current path.
    static func blobSource(for file: FileDiff, side: Side) -> BlobSource? {
        let oldPath = file.oldPath ?? file.path
        switch (file.scope, side) {
        case (.unstaged, .old): return .git(["show", ":\(oldPath)"])
        case (.unstaged, .new): return .workingTree(path: file.path)
        case (.staged, .old): return .git(["show", "HEAD:\(oldPath)"])
        case (.staged, .new): return .git(["show", ":\(file.path)"])
        case (.committed, .old):
            guard let sha = file.baseSHA else { return nil }
            return .git(["show", "\(sha):\(oldPath)"])
        case (.committed, .new): return .git(["show", "\(file.headRef ?? "HEAD"):\(file.path)"])
        }
    }

    /// The whole-file text for one side of `file`, for syntax highlighting (ZEN-239). A side whose blob
    /// doesn't exist (an added file's old side, a deleted file's new side) makes `git show` fail and
    /// returns nil, so the caller renders that side plain. Blocking git — call off-main.
    static func blobText(for file: FileDiff, side: Side, repoRoot: URL) -> String? {
        switch blobSource(for: file, side: side) {
        case .none: return nil
        case .git(let args): return try? runGit(args, in: repoRoot)
        case .workingTree(let path):
            return try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
        }
    }

    /// The ref the committed slice forks from, when the caller doesn't name one: the repo's default
    /// branch (`origin/HEAD`), else `main`/`master`. Git records no parent-branch, so guessing a
    /// stacked branch's parent is unreliable; the viewer defaults to the default branch and lets the
    /// user pick a different base. Throws when none resolves (a fresh repo with only the root commit).
    private static func resolveDefaultBase(in repoRoot: URL) throws -> String {
        if let ref = try? runGit(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: repoRoot),
            let name = defaultBranchName(fromSymbolicRef: ref)
        {
            return name
        }
        for candidate in ["main", "master"] {
            if (try? runGit(["rev-parse", "--verify", "--quiet", candidate], in: repoRoot)) != nil {
                return candidate
            }
        }
        throw Failure.gitError("no base branch (origin/HEAD, main, or master)")
    }

    /// The ref to hand `merge-base` for a base name. `resolveDefaultBase` strips the `origin/` off the
    /// default (so it reads as `main`, not `origin/main`), but a repo can have `origin/main` as its
    /// default without a local `main` checked out — `merge-base main HEAD` then fails. Fall back to
    /// `origin/<name>` when the bare name doesn't resolve, so the committed slice still loads.
    private static func existingRef(for name: String, in repoRoot: URL) -> String {
        if (try? runGit(["rev-parse", "--verify", "--quiet", name], in: repoRoot)) != nil {
            return name
        }
        return "origin/\(name)"
    }

    /// Untracked file paths and their text contents. Files that can't be read as UTF-8 (binaries)
    /// are skipped rather than shown as garbage.
    private static func readUntracked(repoRoot: URL) -> [(path: String, contents: String)] {
        guard let listing = try? runGit(["ls-files", "--others", "--exclude-standard", "-z"], in: repoRoot)
        else { return [] }
        return listing.split(separator: "\0").compactMap { segment -> (path: String, contents: String)? in
            let path = String(segment)
            guard let contents = try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            else { return nil }
            return (path, contents)
        }
    }

    /// Runs `/usr/bin/git` with `args` in `dir` and returns stdout. Both pipes are drained to EOF
    /// *before* `waitUntilExit`, and stderr is drained on a second queue concurrently with stdout: a
    /// command that fills both pipe buffers can't deadlock. Runs on the background queue, so the
    /// `waitUntilExit` here never blocks main (ZEN-90).
    private static func runGit(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = dir
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw Failure.gitUnavailable
        }

        let stderrHandle = stderr.fileHandleForReading
        var errData = Data()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            errData = stderrHandle.readDataToEndOfFile()
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.gitError(message.isEmpty ? "git exited \(process.terminationStatus)" : message)
        }
        return String(decoding: outData, as: UTF8.self)
    }
}
