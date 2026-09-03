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
            focus: parent.focus, env: parent.env)
    }
}

/// What a clone would lose if it were removed now.
struct CloneState: Equatable {
    let uncommitted: Int
    let unpushed: Int

    var isClean: Bool { uncommitted == 0 && unpushed == 0 }
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
            let slug = slug(for: workspace.title)
            let dir = root.appendingPathComponent(slug, isDirectory: true)
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

        let slug = slug(for: workspace.title)
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try verifySameVolume(source, dir)

        let number = nextNumber(in: dir, slug: slug)
        let name = "c\(number)"
        let destination = dir.appendingPathComponent("\(slug)-\(name)", isDirectory: true)

        // clonefile, not `cp -Rc`: it clones the whole hierarchy in one call and reports a real
        // errno, where `cp -c` degrades to a full byte copy without saying so.
        guard clonefile(source.path, destination.path, 0) == 0 else {
            throw CloneError.cloneFailed(errno)
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
            // The build cache is the one gitignored exception: it bakes in absolute paths — Clang's
            // module cache, PCH validation, llbuild's manifest — tied to the ORIGINAL location.
            // Reused from the clone's own path it doesn't degrade to a slow rebuild, it fails
            // outright: "PCH was compiled with module cache path X, but the path is currently Y" is
            // a hard error, not a cache miss. Strip it so the clone's first build is cold but
            // correct.
            let buildCache = destination.appendingPathComponent(".build", isDirectory: true)
            if FileManager.default.fileExists(atPath: buildCache.path) {
                try FileManager.default.removeItem(at: buildCache)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        return Clone(workspaceTitle: workspace.title, name: name, path: destination, branch: branch)
    }

    /// Uncommitted files and commits that are on no remote. Two git calls, so callers keep it off
    /// the path that renders rows and ask only when the answer is about to be shown.
    static func state(_ clone: Clone) -> CloneState {
        let status = (try? git(["status", "--porcelain"], in: clone.path)) ?? ""
        let uncommitted = status.isEmpty ? 0 : status.split(separator: "\n").count
        let counted = (try? git(["rev-list", "--count", "HEAD", "--not", "--remotes"], in: clone.path)) ?? ""
        return CloneState(uncommitted: uncommitted, unpushed: Int(counted) ?? 0)
    }

    /// Delete the clone. Copy-on-write means this frees only the blocks that diverged.
    static func remove(_ clone: Clone) throws {
        try FileManager.default.removeItem(at: clone.path)
    }

    // MARK: helpers

    /// A path segment from a workspace title, which is free text and may hold anything.
    static func slug(for title: String) -> String {
        let kept = title.map { character -> Character in
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
