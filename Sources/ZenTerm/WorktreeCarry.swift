import Foundation

// Nothing throws: a missing entry is normal and must never stop a worktree being made.
struct CarryReport: Equatable {
    struct Skipped: Equatable {
        enum Reason: Equatable {
            case leavesTheWorkspace
            case notThere
            // Carrying it would leave git reporting a modification forever.
            case tracked
            case unreadable
            case alreadyInTheWorktree
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

struct IgnoredCatalog: Equatable {
    let entries: [String]
    let resting: [String]
    let fileCounts: [String: Int]
    let directories: Set<String>
}

// Blocking, and it can move gigabytes: never call it on main.
enum WorktreeCarry {
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
            guard !entryExists(at: to) else {
                skip(name, .alreadyInTheWorktree)
                continue
            }

            let parent = to.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                skip(name, .copyFailed(error.localizedDescription))
                continue
            }

            let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_RECURSIVE)
            guard copyfile(from.path, to.path, nil, flags) == 0 else {
                var message = [CChar](repeating: 0, count: 256)
                strerror_r(errno, &message, message.count)
                let reason = String(cString: message)
                try? FileManager.default.removeItem(at: to)
                skip(name, .copyFailed(reason))
                continue
            }
            carried.append(name)
        }
        return CarryReport(carried: carried, skipped: skipped)
    }

    static func ignoredEntries(in workspace: URL, chosen: Set<String>) -> IgnoredCatalog? {
        guard let reported = ignoredPaths(in: workspace, under: nil) else { return nil }
        return fold(reported, chosen: chosen)
    }

    // Git collapses a folder only when it tracks nothing inside, so a tracked `.keep` sprays every file.
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
        let folded = files.filter { parent, kids in
            kids.count > 1 && !chosenParents.contains(parent)
                && !directories.contains { ($0 as NSString).deletingLastPathComponent == parent }
        }
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

    // Porcelain paths are relative to the repo root, not the directory git ran in.
    private static func ignoredPaths(in workspace: URL, under path: String?)
        -> [(path: String, isDirectory: Bool)]?
    {
        guard let prefix = repoPrefix(of: workspace) else { return nil }
        var args = ["--literal-pathspecs", "status", "--porcelain", "--ignored", "-z"]
        if let path { args += ["--", prefix + path] }
        guard case .success(let output) = GitCommand.run(args, in: workspace) else { return nil }
        return output.split(separator: "\0").compactMap { line in
            guard line.hasPrefix("!! ") else { return nil }
            var entry = line.dropFirst(3)
            if entry.hasSuffix("/") { entry = entry.dropLast() }
            guard entry.hasPrefix(prefix) else { return nil }
            let relative = String(entry.dropFirst(prefix.count))
            guard !relative.isEmpty else { return nil }
            return (relative, line.hasSuffix("/"))
        }
    }

    private static func repoPrefix(of workspace: URL) -> String? {
        guard case .success(let output) = GitCommand.run(["rev-parse", "--show-prefix"], in: workspace)
        else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // `--` ends option parsing but not pathspec globbing, hence `--literal-pathspecs`.
    private static func isTracked(_ name: String, in repo: URL) -> Bool? {
        let args = ["--literal-pathspecs", "ls-files", "-z", "--", name]
        switch GitCommand.run(args, in: repo) {
        case .success(let output): return !output.isEmpty
        case .failure: return nil
        }
    }

    private static func copyIgnoredContents(of name: String, from source: URL, into worktree: URL)
        -> CarryReport.Skipped.Reason?
    {
        guard let inside = ignoredPaths(in: source, under: name) else { return .unreadable }
        guard !inside.isEmpty else { return .notThere }
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

    // `containedPath` is lexical; a checked-out symlink would let `copyfile` write outside the tree.
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

    // `COPYFILE_CLONE` implies `COPYFILE_NOFOLLOW_SRC`, so a link pointing out arrives dangling.
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

    // `COPYFILE_CLONE` onto an existing directory returns 0 having copied nothing, and `fileExists` follows links.
    private static func entryExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func containedPath(_ name: String, under root: URL) -> URL? {
        let base = root.standardizedFileURL
        let target = base.appendingPathComponent(name).standardizedFileURL
        guard target != base, target.path.hasPrefix(base.path + "/") else { return nil }
        return target
    }
}
