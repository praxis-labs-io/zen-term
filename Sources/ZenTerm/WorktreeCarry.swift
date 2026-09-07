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

/// Copies into a fresh worktree the gitignored entries a project needs to run. An allowlist, since
/// subtracting what breaks on relocation asks us to know every ecosystem's landmines.
///
/// Blocking, and it can move gigabytes: the caller owns the queue hop. Never call this on main.
enum WorktreeCarry {
    /// Bring `entries` across in authored order, and report what did not make it.
    static func copy(_ entries: [String], from source: URL, into worktree: URL) -> CarryReport {
        var carried: [String] = []
        var skipped: [CarryReport.Skipped] = []

        func skip(_ name: String, _ reason: CarryReport.Skipped.Reason) {
            skipped.append(CarryReport.Skipped(name: name, reason: reason))
        }

        for name in entries {
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
            // `COPYFILE_CLONE` implies `COPYFILE_NOFOLLOW_SRC`, so a symlink arrives as a symlink
            // with its original target. A worktree sits under a different parent, so one pointing
            // outside the workspace lands dangling while the report calls it carried.
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: from.path) {
                let resolved = URL(
                    fileURLWithPath: target, relativeTo: from.deletingLastPathComponent()
                ).standardizedFileURL
                guard resolved.path.hasPrefix(source.standardizedFileURL.path + "/") else {
                    skip(name, .leavesTheWorkspace)
                    continue
                }
            }
            switch isTracked(name, in: source) {
            case .some(true): skip(name, .tracked); continue
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
