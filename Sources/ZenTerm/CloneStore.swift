import CryptoKit
import Foundation

/// One parallel copy of a workspace: its own directory, its own branch, nothing shared with the
/// original but the blocks APFS holds in common.
struct Clone: Equatable {
    /// The parent workspace's title, as the picker shows it.
    let workspaceTitle: String
    /// The clone's identifier under that workspace: "c2", "c3". The parent workspace is the
    /// implicit first copy, so numbering starts at 2 rather than claiming "c1" for something the
    /// picker already shows unadorned.
    let name: String
    /// The checkout, at `<clones>/<slug>/<slug>-<name>` — `zen-term-c2` beside `zen-term`'s own
    /// checkout, not a bare "c2": legible in a directory listing or a shell's tab completion with
    /// nothing else open, on its own.
    let path: URL
    /// The branch checked out at creation, e.g. `main` — whatever the parent's own default
    /// branch is called, not a clone-specific name. A clone is a standalone repo, so there is
    /// nothing for it to collide with.
    let branch: String

    /// What the tab is called, and the title of the derived workspace that opens it.
    var title: String { "\(workspaceTitle) \(name)" }

    /// The parent's recipe pointed at the clone, so a clone opens through the ordinary workspace
    /// path with nothing new behind it.
    func workspace(from parent: Workspace) -> Workspace {
        Workspace(
            title: title, path: path, main: parent.main, right: parent.right, bottom: parent.bottom,
            focus: parent.focus, env: parent.env, cloneExclude: parent.cloneExclude)
    }
}

/// What a clone would lose if it were removed now.
struct CloneState: Equatable {
    let uncommitted: Int
    /// Commits on *any* local branch that no remote has and that the clone did not start with.
    /// Every local branch, not just HEAD's: work parked on a side branch you are not standing on
    /// is exactly the work a person forgets they left behind.
    let unpushed: Int
    /// Stash entries made since the clone was created.
    let stashed: Int

    var isClean: Bool { uncommitted == 0 && unpushed == 0 && stashed == 0 }
}

/// Creates, finds and removes workspace clones under `~/.zenterm/clones/`.
///
/// Every call blocks on the filesystem or on `git`, so callers run them off-main and hop back,
/// the way `GitRepoStatus` wraps `GitRepo`.
enum CloneStore {
    enum CloneError: Error, LocalizedError, Equatable {
        case notARepo(URL)
        case notAWholeRepo(URL)
        case differentVolume
        case noBaseBranch
        case cloneFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .notARepo(let url):
                return "\(url.lastPathComponent) is not a git repository."
            case .notAWholeRepo(let url):
                return "\(url.lastPathComponent) is a worktree, not a whole repository."
            case .differentVolume:
                return "The clones folder is on a different volume, so a clone would be a full copy."
            case .noBaseBranch:
                return "This repository has no origin/main to branch from."
            case .cloneFailed(let code):
                return String(cString: strerror(code))
            }
        }
    }

    #if DEBUG
        /// Test-only redirect, mirroring `ConfigLoader.defaultRootOverrideForTesting`.
        static var rootOverrideForTesting: URL?
    #endif

    /// Clones live beside neither the config nor the app-state directory: a clone is a working tree
    /// the user opens a shell in, so it gets a plain, typeable home of its own.
    static var root: URL {
        #if DEBUG
            if let rootOverrideForTesting { return rootOverrideForTesting }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zenterm/clones", isDirectory: true)
    }

    /// Every clone belonging to one of `workspaces`, parent order preserved, numbered order within.
    /// A directory with no matching workspace is ignored, and a clone deleted by hand simply stops
    /// being listed.
    static func list(for workspaces: [Workspace]) -> [Clone] {
        workspaces.flatMap { workspace -> [Clone] in
            let slug = slug(for: workspace)
            let dir = root.appendingPathComponent(directoryName(for: workspace), isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return
                names
                .compactMap { cloneNumber(from: $0, slug: slug) }
                .sorted()
                .map { number in
                    let name = "c\(number)"
                    return Clone(
                        workspaceTitle: workspace.title, name: name,
                        path: dir.appendingPathComponent("\(slug)-\(name)", isDirectory: true),
                        branch: "main")
                }
        }
    }

    /// Copy-on-write clone the workspace, then check the copy out on the parent's own default
    /// branch — `main`, or whatever `origin/HEAD` actually points to.
    static func create(from workspace: Workspace) throws -> Clone {
        let source = workspace.path.standardizedFileURL
        try verifyWholeRepo(at: source)

        let slug = slug(for: workspace)
        let dir = root.appendingPathComponent(directoryName(for: workspace), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try verifySameVolume(source, dir)

        // `clonefile` is the claim on the number, not `nextNumber`: two clones started at once
        // (one double-tap of ⌥⏎) both read the directory before either has written to it, both
        // pick the same number, and the loser fails with EEXIST reported as "File exists". Taking
        // EEXIST as "someone got there first" and asking for the next number is the answer at the
        // layer the race is on, and it holds across two windows or two processes as well.
        var name = ""
        var destination = dir
        while true {
            let number = nextNumber(in: dir, slug: slug)
            name = "c\(number)"
            destination = dir.appendingPathComponent("\(slug)-\(name)", isDirectory: true)
            // clonefile, not `cp -Rc`: it clones the whole hierarchy in one call and reports a real
            // errno, where `cp -c` degrades to a full byte copy without saying so.
            if clonefile(source.path, destination.path, 0) == 0 { break }
            guard errno == EEXIST else { throw CloneError.cloneFailed(errno) }
        }

        let branch: String
        do {
            let base = try resolveBase(in: destination)
            branch = String(base.dropFirst("origin/".count))
            try git(["checkout", "-B", branch, base, "--force"], in: destination)
            // `checkout --force` resets tracked files but never touches untracked ones. Drop the
            // ones outside `.gitignore` — whatever the parent's working branch had in progress and
            // never told git about — so a clone starts clean of that; `-fd` alone leaves anything
            // gitignored alone, so `.env`, `node_modules`, and every other locally-necessary
            // ignored file still ride along.
            try git(["clean", "-fd"], in: destination)
            try stripUnrelocatable(in: destination, declared: workspace.cloneExclude)
            try recordBaseline(in: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        return Clone(workspaceTitle: workspace.title, name: name, path: destination, branch: branch)
    }

    /// What removing the clone would destroy, or nil when that cannot be determined. Several git
    /// calls, so callers keep it off the path that renders rows and ask only when the answer is
    /// about to be shown.
    ///
    /// **Nil is not "clean".** Reporting zero when git failed would put "nothing uncommitted" in
    /// front of a person about to delete a repository we could not read, which is the one sentence
    /// this function exists to get right. The caller says so and keeps the destructive framing.
    ///
    /// Measured against the baseline recorded at creation, not against the repo's whole contents:
    /// a clone inherits the parent's local branches and stashes through the copy, so counting
    /// those would mark every brand-new clone as dirty and train the warning away.
    static func state(_ clone: Clone) -> CloneState? {
        guard let status = try? git(["status", "--porcelain"], in: clone.path),
            let counted = try? git(
                ["rev-list", "--count", "--branches", "--not", "--remotes", "--glob=\(baseNamespace)"],
                in: clone.path),
            let unpushed = Int(counted),
            let stash = try? git(["stash", "list"], in: clone.path)
        else { return nil }
        let stashBaseline =
            (try? git(["config", "--local", "--get", stashBaselineKey], in: clone.path))
            .flatMap(Int.init) ?? 0
        return CloneState(
            uncommitted: lineCount(status), unpushed: unpushed,
            stashed: max(0, lineCount(stash) - stashBaseline))
    }

    private static func lineCount(_ output: String) -> Int {
        output.isEmpty ? 0 : output.split(separator: "\n").count
    }

    /// Where the creation-time branch tips are parked, and where the creation-time stash depth is.
    private static let baseNamespace = "refs/zenterm-base"
    private static let stashBaselineKey = "zenterm.stashbase"

    /// Snapshot what the clone started with, so `state` can later tell inherited work from work
    /// done here. The copy carries the parent's local branches and stashes, and those are the
    /// parent's, not this clone's, however much they look alike.
    ///
    /// Cleared before it is written: cloning a clone would otherwise inherit the older namespace
    /// and keep measuring against the wrong starting point.
    private static func recordBaseline(in clone: URL) throws {
        let existing = try git(["for-each-ref", "--format=%(refname)", baseNamespace], in: clone)
        for ref in existing.split(separator: "\n") {
            try git(["update-ref", "-d", String(ref)], in: clone)
        }
        let heads = try git(["for-each-ref", "--format=%(objectname) %(refname:short)", "refs/heads"], in: clone)
        for line in heads.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            try git(["update-ref", "\(baseNamespace)/\(parts[1])", String(parts[0])], in: clone)
        }
        let stashDepth = lineCount((try? git(["stash", "list"], in: clone)) ?? "")
        try git(["config", "--local", stashBaselineKey, String(stashDepth)], in: clone)
    }

    #if DEBUG
        /// Test-only, and the only way to observe the window's in-flight state: deleting a real
        /// clone takes tens of seconds, deleting a fixture takes none, so a test cannot otherwise
        /// catch the picker mid-removal.
        static var willRemoveForTesting: ((Clone) -> Void)?
    #endif

    /// Delete the clone. Copy-on-write means this frees only the blocks that diverged.
    static func remove(_ clone: Clone) throws {
        #if DEBUG
            willRemoveForTesting?(clone)
        #endif
        try FileManager.default.removeItem(at: clone.path)
    }

    // MARK: what a clone must not carry

    /// Marker files that identify an artifact directory which breaks when the checkout moves,
    /// because it writes an absolute interpreter or compiler path into what it builds.
    ///
    /// Matched on the marker rather than the directory's name: a virtualenv called `venv311` is
    /// as broken by relocation as one called `venv`, and a name list only ever knows the names it
    /// was written with. Measured on the repos to hand, the failures are a dangling
    /// `bin/python3` and "PCH was compiled with module cache path X, but the path is currently Y"
    /// — hard errors, not cache misses.
    ///
    /// Deliberately short. `node_modules`, `.turbo` and `.next` all survive relocation (`.turbo`
    /// turns a 33s first build into 1.5s), so carrying them is the point of cloning at all.
    private static let breakingMarkers = [
        "pyvenv.cfg",  // a Python virtualenv: absolute shebangs, absolute `home` in the config
        "build.db",  // SwiftPM/llbuild: absolute paths through the module cache and PCH validation
    ]

    /// Remove what the clone cannot use at its new path: the directories the user named in
    /// `clone_exclude`, then any top-level artifact directory carrying a marker.
    ///
    /// Top level only, which is where every such directory was found across the repos to hand.
    /// Anything nested is `clone_exclude`'s job, and a whole-tree walk would have to descend
    /// through a multi-gigabyte `node_modules` to find nothing.
    private static func stripUnrelocatable(in clone: URL, declared: [String]) throws {
        for name in declared {
            guard let target = containedPath(name, under: clone),
                FileManager.default.fileExists(atPath: target.path)
            else { continue }
            try FileManager.default.removeItem(at: target)
        }
        for directory in topLevelDirectories(of: clone) where carriesBreakingMarker(directory) {
            // Only what git ignores. `build.db` is a common enough filename that a tracked
            // `data/` directory could carry one, and deleting tracked files would leave the clone
            // missing content the checkout just restored.
            guard isIgnored(directory, in: clone) else { continue }
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// `name` resolved under `clone`, or nil if it lands anywhere else. The parser already refuses
    /// an escaping `clone_exclude`; this is the check at the point the delete actually happens.
    private static func containedPath(_ name: String, under clone: URL) -> URL? {
        let root = clone.standardizedFileURL
        let target = root.appendingPathComponent(name).standardizedFileURL
        guard target != root, target.path.hasPrefix(root.path + "/") else { return nil }
        return target
    }

    private static func topLevelDirectories(of clone: URL) -> [URL] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: clone, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    private static func carriesBreakingMarker(_ directory: URL) -> Bool {
        breakingMarkers.contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    private static func isIgnored(_ directory: URL, in clone: URL) -> Bool {
        (try? git(["check-ignore", "--quiet", "--", directory.lastPathComponent], in: clone)) != nil
    }

    // MARK: helpers

    /// The readable half of a clone's name, taken from the workspace folder rather than its title:
    /// a clone of `~/Dev/zen-term` is `zen-term-c2` however the picker labels it, and renaming the
    /// workspace does not rename what is already on disk.
    static func slug(for workspace: Workspace) -> String {
        slug(forText: workspace.path.standardizedFileURL.lastPathComponent)
    }

    /// The directory holding one workspace's clones. Keyed on the **path**, not the title, and
    /// carrying a digest of it.
    ///
    /// Titles do not identify a workspace. `slug` folds case and punctuation, so "Zen Term",
    /// "zen term" and "zen/term" all land on `zen-term` while `WorkspacesWriter` only refuses an
    /// exact duplicate: two such workspaces would share a directory, show each other's clones, and
    /// delete each other's on ⌥⌫. A title is also editable, and renaming one would orphan every
    /// clone it already had.
    static func directoryName(for workspace: Workspace) -> String {
        "\(slug(for: workspace))-\(digest(of: workspace.path))"
    }

    /// Eight hex characters of SHA-256 over the standardized path. Long enough that two workspaces
    /// on one machine will not collide, short enough to type.
    private static func digest(of path: URL) -> String {
        let data = Data(path.standardizedFileURL.path.utf8)
        return SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// One path segment from free text, which may hold anything.
    static func slug(forText text: String) -> String {
        let kept = text.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character : "-"
        }
        let collapsed = String(kept).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "workspace" : collapsed.lowercased()
    }

    /// Numbering starts at 2: the workspace itself is the first copy.
    private static func nextNumber(in dir: URL, slug: String) -> Int {
        let taken = Set(
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .compactMap { cloneNumber(from: $0, slug: slug) })
        var number = 2
        while taken.contains(number) { number += 1 }
        return number
    }

    /// The number in a clone directory's `<slug>-c<n>` name, or nil for anything else that name
    /// filters out a stray sibling directory.
    private static func cloneNumber(from dirName: String, slug: String) -> Int? {
        let prefix = "\(slug)-c"
        guard dirName.hasPrefix(prefix) else { return nil }
        return Int(dirName.dropFirst(prefix.count))
    }

    private static func verifyWholeRepo(at source: URL) throws {
        guard GitRepo.isGitRepo(source) else { throw CloneError.notARepo(source) }
        // A worktree's `.git` is a file pointing back into the parent's admin dir, so cloning it
        // would hand two trees the same bookkeeping.
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(
            atPath: source.appendingPathComponent(".git").path, isDirectory: &isDirectory)
        guard isDirectory.boolValue else { throw CloneError.notAWholeRepo(source) }
    }

    /// Extents are volume-local: across volumes there is no clone, only a full copy of every byte.
    private static func verifySameVolume(_ lhs: URL, _ rhs: URL) throws {
        let ids = [lhs, rhs].map { url -> NSObject? in
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let first = ids[0], let second = ids[1], first.isEqual(second) else {
            throw CloneError.differentVolume
        }
    }

    private static func resolveBase(in dir: URL) throws -> String {
        if (try? git(["rev-parse", "--verify", "--quiet", "origin/main"], in: dir)) != nil {
            return "origin/main"
        }
        if let head = try? git(["symbolic-ref", "refs/remotes/origin/HEAD"], in: dir),
            let name = head.split(separator: "/").last, !name.isEmpty
        {
            return "origin/\(name)"
        }
        throw CloneError.noBaseBranch
    }

    @discardableResult
    private static func git(_ args: [String], in dir: URL) throws -> String {
        try GitCommand.run(args, in: dir).get()
    }
}
