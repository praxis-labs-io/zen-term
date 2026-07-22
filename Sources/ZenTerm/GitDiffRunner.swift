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
    struct StatusLoad: Equatable {
        let unstaged: [FileDiff]
        let staged: [FileDiff]
        let committed: [FileDiff]
        let baseBranch: String?
        let baseSHA: String?

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
    func loadStatus(base: String? = nil, completion: @escaping (Result<StatusLoad, Failure>) -> Void) {
        let repoRoot = self.repoRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<StatusLoad, Failure>
            do {
                result = .success(try Self.loadSync(base: base, repoRoot: repoRoot))
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
            let current = (try? Self.runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ordered = Self.orderedBranches(recency: recency, default: preferred, current: current)
            DispatchQueue.main.async { completion(ordered) }
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// The base dropdown's branch order: the default branch first (so `main` sits on top even when it
    /// hasn't been committed to recently), then every other branch by the recency order git returned,
    /// deduplicated. The `current` (checked-out) branch is excluded outright — comparing the committed
    /// work against the branch it's on is meaningless. A `default` not among the local branches is
    /// still pinned first (it may be a remote default the user forks from without a local branch),
    /// unless it *is* the current branch.
    static func orderedBranches(recency: [String], default preferred: String?, current: String?) -> [String] {
        var seen = Set<String>()
        if let current, !current.isEmpty { seen.insert(current) }  // never offer the checked-out branch
        var ordered: [String] = []
        func add(_ name: String) {
            guard seen.insert(name).inserted else { return }
            ordered.append(name)
        }
        if let preferred, !preferred.isEmpty { add(preferred) }
        recency.forEach(add)
        return ordered
    }

    /// The `git diff` argument list for a slice. `--no-color`/`--no-ext-diff` keep the output a plain
    /// unified diff the parser can read regardless of git config; `--find-renames` makes a moved file
    /// read as a rename rather than an add plus a delete. Unstaged is working-tree vs index; staged is
    /// index vs HEAD (`--cached`); committed is the fork point (`mergeBase`) vs HEAD.
    static func diffArguments(scope: DiffScope, mergeBase: String) -> [String] {
        let base = ["diff", "--no-color", "--no-ext-diff", "--find-renames"]
        switch scope {
        case .unstaged: return base
        case .staged: return base + ["--cached"]
        case .committed: return base + [mergeBase, "HEAD"]
        }
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
    private static func loadSync(base: String?, repoRoot: URL) throws -> StatusLoad {
        let unstagedPatch = try runGit(diffArguments(scope: .unstaged, mergeBase: ""), in: repoRoot)
        let stagedPatch = try runGit(diffArguments(scope: .staged, mergeBase: ""), in: repoRoot)

        var baseBranch: String?
        var baseSHA: String?
        var committedPatch = ""
        if let resolved = base ?? (try? resolveDefaultBase(in: repoRoot)) {
            let ref = existingRef(for: resolved, in: repoRoot)
            let mergeBase = try runGit(["merge-base", ref, "HEAD"], in: repoRoot)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            baseBranch = defaultBranchName(fromSymbolicRef: resolved)
            baseSHA = String(mergeBase.prefix(7))
            committedPatch = try runGit(diffArguments(scope: .committed, mergeBase: mergeBase), in: repoRoot)
        }

        var unstaged = DiffParser.parse(unstagedPatch)
        unstaged += syntheticUntrackedDiffs(untrackedFiles: readUntracked(repoRoot: repoRoot))
        return StatusLoad(
            unstaged: unstaged,
            staged: DiffParser.parse(stagedPatch),
            committed: DiffParser.parse(committedPatch),
            baseBranch: baseBranch,
            baseSHA: baseSHA)
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
