import Foundation

/// What a carry brought across, and what it did not.
///
/// Nothing here throws: a config naming an entry this repo does not have is a normal state, not a
/// failure, and it must never stop a worktree being made.
struct CarryReport: Equatable {
    /// One entry that did not come across, and why.
    struct Skipped: Equatable {
        enum Reason: Equatable {
            /// Resolves outside the workspace, so copying it would reach somewhere else.
            case leavesTheWorkspace
            case notThere
            /// Git tracks content under it. Carrying that would report a modification forever.
            case tracked
            /// Git could not be asked, so whether it is tracked is unknown.
            case unreadable
            case alreadyInTheWorktree
            /// `strerror` of the errno `copyfile` reported.
            case copyFailed(String)
        }

        let name: String
        let reason: Reason
    }

    let carried: [String]
    let skipped: [Skipped]

    var isEmpty: Bool { carried.isEmpty && skipped.isEmpty }
}

extension CarryReport.Skipped.Reason {
    /// The tail of a sentence starting with the entry's name.
    var explanation: String {
        switch self {
        case .leavesTheWorkspace: return "points outside the workspace"
        case .notThere: return "isn't there"
        case .tracked: return "is tracked by git"
        case .unreadable: return "couldn't be checked with git"
        case .alreadyInTheWorktree: return "was already in the worktree"
        case .copyFailed(let reason): return "didn't copy: \(reason)"
        }
    }
}

/// What a workspace could copy, and what to show at rest.
struct IgnoredCatalog: Equatable {
    /// Every row, unfolded: a folded folder followed by the files it stands in for. What a query
    /// searches, so a single file inside a folded folder is still pickable by name.
    let entries: [String]
    /// The subset shown while nothing is typed.
    let resting: [String]
    /// How many files each folded folder stands in for.
    let fileCounts: [String: Int]
    /// Which entries are folders, so the list can tell the two kinds apart at a glance.
    let directories: Set<String>
}

/// Copies into a fresh worktree the gitignored entries a project needs to run. An allowlist, since
/// subtracting what breaks on relocation asks us to know every ecosystem's landmines.
///
/// Blocking, and it can move gigabytes: the caller owns the queue hop. Never call this on main.
enum WorktreeCarry {
    /// In authored order. `onEntry` fires off-main as each one starts.
    static func copy(
        _ entries: [String], from source: URL, into worktree: URL,
        onEntry: ((String) -> Void)? = nil
    ) -> CarryReport {
        var carried: [String] = []
        var skipped: [CarryReport.Skipped] = []

        func skip(_ name: String, _ reason: CarryReport.Skipped.Reason) {
            skipped.append(CarryReport.Skipped(name: name, reason: reason))
        }

        for name in entries {
            onEntry?(name)
            guard let from = containedPath(name, under: source),
                let to = containedPath(name, under: worktree)
            else {
                skip(name, .leavesTheWorkspace)
                continue
            }
            guard FileManager.default.fileExists(atPath: from.path) else {
                skip(name, .notThere)
                continue
            }
            guard symlinkStaysInside(from, source), resolvesInside(to, worktree) else {
                skip(name, .leavesTheWorkspace)
                continue
            }
            switch isTracked(name, in: source) {
            case .some(true):
                // A folder git tracks something inside is one the picker folds into a single row,
                // so the row has to mean what it says: bring the ignored content, leave the rest.
                // A tracked *file* is still refused, because copying one reports a modification
                // that never goes away.
                guard isDirectory(from) else {
                    skip(name, .tracked)
                    continue
                }
                if let reason = copyIgnoredContents(of: name, from: source, into: worktree) {
                    skip(name, reason)
                } else {
                    carried.append(name)
                }
                continue
            case .none: skip(name, .unreadable); continue
            case .some(false): break
            }
            // `COPYFILE_CLONE` implies `COPYFILE_EXCL`, but that only refuses a *file*: copying a
            // directory onto one that exists returns 0 and copies nothing. Probed on macOS 25.5.
            // No-follow, or a dangling link here reads as absent and the cleanup deletes it.
            guard !entryExists(at: to) else {
                skip(name, .alreadyInTheWorktree)
                continue
            }

            // A nested entry can land under a directory the worktree does not have, because git
            // gave it only what it tracks. One left empty by a failed copy shows in no `git status`.
            let parent = to.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                skip(name, .copyFailed(error.localizedDescription))
                continue
            }

            let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_RECURSIVE)
            guard copyfile(from.path, to.path, nil, flags) == 0 else {
                // `strerror` hands back a shared static buffer, so two creates failing at once can
                // report each other's message.
                var message = [CChar](repeating: 0, count: 256)
                strerror_r(errno, &message, message.count)
                let reason = String(cString: message)
                // A recursive copy can die partway through and leave half a `node_modules`, which
                // a package manager can read as an install it need not redo.
                try? FileManager.default.removeItem(at: to)
                skip(name, .copyFailed(reason))
                continue
            }
            carried.append(name)
        }
        return CarryReport(carried: carried, skipped: skipped)
    }

    /// What git ignores in `workspace`, as paths relative to it, or nil when git could not be
    /// asked. An ignored directory arrives collapsed to one entry, which is what carry copies at.
    /// `chosen` is what the workspace already copies. A folder holding one of those stays
    /// expanded, so the pick sits among its siblings rather than behind a row that means more.
    static func ignoredEntries(in workspace: URL, chosen: Set<String>) -> IgnoredCatalog? {
        guard let reported = ignoredPaths(in: workspace, under: nil) else { return nil }
        return fold(reported, chosen: chosen)
    }

    /// One row per folder that sprays ignored *files*, in place of the files. Git collapses a
    /// folder only when it tracks nothing inside, so a Rails `log/` with a tracked `.keep` reports
    /// every rotated log on its own: 170 rows out of craftwork's 249 came from that one folder.
    ///
    /// Only files fold. A folder whose ignored children are themselves folders is already one row
    /// each, and folding it would hide the difference between a `node_modules` worth copying and a
    /// `.cache` that is not.
    private static func fold(_ reported: [(path: String, isDirectory: Bool)], chosen: Set<String>)
        -> IgnoredCatalog
    {
        let chosenParents = Set(chosen.map { ($0 as NSString).deletingLastPathComponent })
        var files: [String: [String]] = [:]
        for entry in reported where !entry.isDirectory {
            let parent = (entry.path as NSString).deletingLastPathComponent
            guard !parent.isEmpty else { continue }
            files[parent, default: []].append(entry.path)
        }
        let directories = Set(reported.filter(\.isDirectory).map(\.path))
        // A parent that also holds an ignored folder keeps its files: folding there would swallow
        // that folder's row into a name that no longer says which of the two it means.
        let folded = files.filter { parent, kids in
            kids.count > 1 && !chosenParents.contains(parent)
                && !directories.contains { ($0 as NSString).deletingLastPathComponent == parent }
        }
        // Every file stays a row, sitting under the folder it folded into: the fold is the
        // resting view, and a query still has to be able to reach a single file inside one.
        var entries: [String] = []
        var resting: [String] = []
        var seen: Set<String> = []
        for entry in reported {
            let parent = (entry.path as NSString).deletingLastPathComponent
            guard !entry.isDirectory, let siblings = folded[parent] else {
                entries.append(entry.path)
                resting.append(entry.path)
                continue
            }
            if seen.insert(parent).inserted {
                entries.append(parent)
                resting.append(parent)
                entries.append(contentsOf: siblings)
            }
        }
        return IgnoredCatalog(
            entries: entries, resting: resting, fileCounts: folded.mapValues(\.count),
            directories: directories.union(folded.keys))
    }

    /// What git ignores, as paths relative to `workspace`, each flagged as a folder or a file.
    /// `under` narrows it to one path. Nil when git could not be asked.
    private static func ignoredPaths(in workspace: URL, under path: String?)
        -> [(path: String, isDirectory: Bool)]?
    {
        // `-z` so a path holding a space or a quote arrives literal; `--porcelain` alone quotes it.
        // Porcelain paths are relative to the repo root, never to the directory git ran in, so a
        // workspace pointing inside a repo has to subtract its own prefix from every one.
        guard let prefix = repoPrefix(of: workspace) else { return nil }
        // `--literal-pathspecs` for the same reason `isTracked` passes it: a real folder named
        // with `*`, `?` or `[` is a glob to git, and would match paths outside the one asked about.
        var args = ["--literal-pathspecs", "status", "--porcelain", "--ignored", "-z"]
        if let path { args += ["--", prefix + path] }
        guard case .success(let output) = GitCommand.run(args, in: workspace) else { return nil }
        return output.split(separator: "\0").compactMap { line in
            guard line.hasPrefix("!! ") else { return nil }
            var entry = line.dropFirst(3)
            if entry.hasSuffix("/") { entry = entry.dropLast() }
            // Outside the workspace, so not ours to offer. A pathspec keeps this empty in practice.
            guard entry.hasPrefix(prefix) else { return nil }
            let relative = String(entry.dropFirst(prefix.count))
            guard !relative.isEmpty else { return nil }
            return (relative, line.hasSuffix("/"))
        }
    }

    /// Where `workspace` sits inside its repo, with a trailing slash, or "" at the root. Nil when
    /// git could not be asked, which is what makes a non-repo folder read as unreadable.
    private static func repoPrefix(of workspace: URL) -> String? {
        guard case .success(let output) = GitCommand.run(["rev-parse", "--show-prefix"], in: workspace)
        else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether git tracks anything at `name`, or nil when git could not be asked. **Nil is not
    /// "untracked":** carrying a tracked path leaves git reporting a modification that never goes
    /// away, so a repo we could not read is one we decline rather than guess about.
    private static func isTracked(_ name: String, in repo: URL) -> Bool? {
        // `--` ends option parsing but not pathspec globbing, so without `--literal-pathspecs` a
        // name holding `*` or `?` matches unrelated tracked files.
        let args = ["--literal-pathspecs", "ls-files", "-z", "--", name]
        switch GitCommand.run(args, in: repo) {
        case .success(let output): return !output.isEmpty
        case .failure: return nil
        }
    }

    /// Copy what git ignores under `name` one entry at a time, for a folder git tracks something
    /// else inside. Whole-folder `copyfile` would bring the tracked content with it.
    /// Nil on success, the refusal otherwise.
    private static func copyIgnoredContents(of name: String, from source: URL, into worktree: URL)
        -> CarryReport.Skipped.Reason?
    {
        // Nothing ignored under it is not the same as git refusing to say. The first is a folder
        // with nothing to bring and stays quiet; the second is declined out loud, the way
        // `isTracked` declines rather than guessing.
        guard let inside = ignoredPaths(in: source, under: name) else { return .unreadable }
        guard !inside.isEmpty else { return .notThere }
        // Everything this call put in the worktree, so a failure partway takes all of it back
        // rather than leaving an install the folder is then reported as not having brought.
        var written: [URL] = []
        func undo(_ reason: CarryReport.Skipped.Reason) -> CarryReport.Skipped.Reason {
            for url in written.reversed() { try? FileManager.default.removeItem(at: url) }
            return reason
        }

        for entry in inside {
            guard let from = containedPath(entry.path, under: source),
                let to = containedPath(entry.path, under: worktree)
            else { return undo(.leavesTheWorkspace) }
            guard symlinkStaysInside(from, source), resolvesInside(to, worktree) else {
                return undo(.leavesTheWorkspace)
            }
            guard !entryExists(at: to) else { continue }
            do {
                try FileManager.default.createDirectory(
                    at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                return undo(.copyFailed(error.localizedDescription))
            }
            let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_RECURSIVE)
            guard copyfile(from.path, to.path, nil, flags) == 0 else {
                var message = [CChar](repeating: 0, count: 256)
                strerror_r(errno, &message, message.count)
                try? FileManager.default.removeItem(at: to)
                return undo(.copyFailed(String(cString: message)))
            }
            written.append(to)
        }
        return nil
    }

    /// Whether `url` still lands under `root` once the symlinks on the way are resolved.
    /// `containedPath` is lexical, so a worktree that checks out a symlink at a carried path would
    /// have `createDirectory` and `copyfile` follow it straight out of the tree. Probed: a copy
    /// through such a parent wrote outside the worktree and reported the folder as carried.
    private static func resolvesInside(_ url: URL, _ root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        var probe = url
        while !entryExists(at: probe) {
            let parent = probe.deletingLastPathComponent()
            guard parent.path != probe.path else { return false }
            probe = parent
        }
        let resolved = probe.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == base || resolved.hasPrefix(base + "/")
    }

    /// Whether a symlink at `from` points somewhere inside `source`. `COPYFILE_CLONE` implies
    /// `COPYFILE_NOFOLLOW_SRC`, so one pointing out arrives dangling under a different parent.
    private static func symlinkStaysInside(_ from: URL, _ source: URL) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: from.path)
        else { return true }
        let resolved = URL(fileURLWithPath: target, relativeTo: from.deletingLastPathComponent())
            .standardizedFileURL
        return resolved.path.hasPrefix(source.standardizedFileURL.path + "/")
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR
    }

    /// Whether anything sits at `url`, a dangling symlink included. `fileExists` follows links.
    private static func entryExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// `name` resolved under `root`, or nil when it lands anywhere else. The parser already refuses
    /// an escaping entry; this is the check at the point the copy actually happens.
    private static func containedPath(_ name: String, under root: URL) -> URL? {
        let base = root.standardizedFileURL
        let target = base.appendingPathComponent(name).standardizedFileURL
        guard target != base, target.path.hasPrefix(base.path + "/") else { return nil }
        return target
    }
}
