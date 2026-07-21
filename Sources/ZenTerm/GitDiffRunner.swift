import Foundation

/// Runs `git` off the main thread and delivers a parsed diff back on main. The app's first
/// real subprocess: everything git-facing for the diff viewer lives here, so the chrome only
/// ever sees `[FileDiff]`. Never blocks the main thread (ZEN-90): the work runs on a global
/// queue and hops back via `DispatchQueue.main.async`.
final class GitDiffRunner {
    /// The repo root the diff is computed from, resolved by the caller via
    /// `GitRepo.repoRoot(for:)`. All git invocations run with this as their working directory.
    let repoRoot: URL

    init(repoRoot: URL) {
        self.repoRoot = repoRoot
    }

    /// What a successful load carries. `baseBranch`/`baseSHA` are nil for `.uncommitted`,
    /// which compares against HEAD rather than a fork point.
    struct DiffLoad: Equatable {
        let scope: DiffScope
        let baseBranch: String?
        let baseSHA: String?
        let files: [FileDiff]
    }

    /// Why a load produced nothing usable. `.gitUnavailable` means git itself couldn't run;
    /// `.gitError` carries git's stderr for the failing command.
    enum Failure: Error, Equatable {
        case gitUnavailable
        case gitError(String)
    }

    /// Loads `scope`'s diff off-main and calls `completion` on the main thread. A prior call
    /// is not cancelled; the caller drives one load at a time (open, then a scope switch).
    func load(scope: DiffScope, completion: @escaping (Result<DiffLoad, Failure>) -> Void) {
        let repoRoot = self.repoRoot
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<DiffLoad, Failure>
            do {
                result = .success(try Self.loadSync(scope: scope, repoRoot: repoRoot))
            } catch let failure as Failure {
                result = .failure(failure)
            } catch {
                result = .failure(.gitError(String(describing: error)))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// The `git diff` argument list for a scope. `--no-color`/`--no-ext-diff` keep the output
    /// a plain unified diff the parser can read regardless of the user's git config;
    /// `--find-renames` makes a moved file read as a rename rather than an add plus a delete.
    static func diffArguments(scope: DiffScope, mergeBase: String) -> [String] {
        let base = ["diff", "--no-color", "--no-ext-diff", "--find-renames"]
        switch scope {
        case .branch: return base + [mergeBase]
        case .committed: return base + [mergeBase, "HEAD"]
        case .uncommitted: return base + ["HEAD"]
        }
    }

    /// The default-branch name from `git symbolic-ref … origin/HEAD` output, e.g.
    /// `origin/release/1.x` -> `release/1.x`. Strips only the leading `origin/`, so a branch
    /// name with slashes survives. Nil when the ref is blank.
    static func defaultBranchName(fromSymbolicRef ref: String) -> String? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prefix = "origin/"
        return trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
    }

    /// Untracked files rendered as synthetic all-added `FileDiff`s, since `git diff` never
    /// shows them. Included for `.branch` and `.uncommitted` (they are part of the working
    /// state); excluded for `.committed` (an untracked file is not in the PR).
    static func syntheticUntrackedDiffs(
        scope: DiffScope, untrackedFiles: [(path: String, contents: String)]
    ) -> [FileDiff] {
        guard scope == .branch || scope == .uncommitted else { return [] }
        return untrackedFiles.map { syntheticAddedDiff(path: $0.path, contents: $0.contents) }
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

    /// Runs synchronously on a background queue: resolves the base, runs the scope's diff,
    /// parses it, and folds in untracked files. Throws `Failure` on any git failure.
    private static func loadSync(scope: DiffScope, repoRoot: URL) throws -> DiffLoad {
        var baseBranch: String?
        var baseSHA: String?
        let patch: String

        switch scope {
        case .branch, .committed:
            let base = try resolveBaseBranch(in: repoRoot)
            let mergeBase = try runGit(["merge-base", base, "HEAD"], in: repoRoot)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            baseBranch = base
            baseSHA = String(mergeBase.prefix(7))
            patch = try runGit(diffArguments(scope: scope, mergeBase: mergeBase), in: repoRoot)
        case .uncommitted:
            patch = try runGit(diffArguments(scope: scope, mergeBase: ""), in: repoRoot)
        }

        var files = DiffParser.parse(patch)
        files += syntheticUntrackedDiffs(scope: scope, untrackedFiles: readUntracked(scope: scope, repoRoot: repoRoot))
        return DiffLoad(scope: scope, baseBranch: baseBranch, baseSHA: baseSHA, files: files)
    }

    /// The base branch to fork from: `origin/HEAD`'s target, or whichever of `main`/`master`
    /// exists locally. Throws when neither can be found.
    private static func resolveBaseBranch(in repoRoot: URL) throws -> String {
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

    /// Untracked file paths and their text contents, or empty for scopes that exclude them.
    /// Files that can't be read as UTF-8 (binaries) are skipped rather than shown as garbage.
    private static func readUntracked(scope: DiffScope, repoRoot: URL) -> [(path: String, contents: String)] {
        guard scope == .branch || scope == .uncommitted else { return [] }
        guard let listing = try? runGit(["ls-files", "--others", "--exclude-standard", "-z"], in: repoRoot)
        else { return [] }
        return listing.split(separator: "\0").compactMap { segment -> (path: String, contents: String)? in
            let path = String(segment)
            guard let contents = try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            else { return nil }
            return (path, contents)
        }
    }

    /// Runs `/usr/bin/git` with `args` in `dir` and returns stdout. Drains the stdout pipe to
    /// EOF *before* `waitUntilExit` so a diff larger than the pipe buffer can't deadlock. This
    /// runs on the background queue, so the `waitUntilExit` here never blocks main (ZEN-90).
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

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.gitError(message.isEmpty ? "git exited \(process.terminationStatus)" : message)
        }
        return String(decoding: outData, as: UTF8.self)
    }
}
