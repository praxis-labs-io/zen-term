import Foundation

/// One parallel copy of a workspace: its own directory, its own branch, nothing shared with the
/// original but the blocks APFS holds in common.
struct Clone: Equatable {
    /// The parent workspace's title, as the picker shows it.
    let workspaceTitle: String
    /// The clone's number under that workspace: "2", "3".
    let name: String
    let path: URL
    let branch: String

    /// What the tab is called, and the title of the derived workspace that opens it.
    var title: String { "\(workspaceTitle) \(name)" }
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
                .compactMap { Int($0) }
                .sorted()
                .map { number in
                    Clone(
                        workspaceTitle: workspace.title, name: String(number),
                        path: dir.appendingPathComponent(String(number), isDirectory: true),
                        branch: "\(slug)-\(number)")
                }
        }
    }

    /// Copy-on-write clone the workspace, then put the copy on a fresh branch off `origin/main`.
    static func create(from workspace: Workspace) throws -> Clone {
        let source = workspace.path.standardizedFileURL
        try verifyWholeRepo(at: source)

        let slug = slug(for: workspace.title)
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try verifySameVolume(source, dir)

        let number = nextNumber(in: dir)
        let destination = dir.appendingPathComponent(String(number), isDirectory: true)
        let branch = "\(slug)-\(number)"

        // clonefile, not `cp -Rc`: it clones the whole hierarchy in one call and reports a real
        // errno, where `cp -c` degrades to a full byte copy without saying so.
        guard clonefile(source.path, destination.path, 0) == 0 else {
            throw CloneError.cloneFailed(errno)
        }

        do {
            let base = try resolveBase(in: destination)
            try git(["checkout", "-B", branch, base, "--force"], in: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        return Clone(
            workspaceTitle: workspace.title, name: String(number), path: destination, branch: branch)
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
    private static func nextNumber(in dir: URL) -> Int {
        let taken = Set(
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap(Int.init))
        var number = 2
        while taken.contains(number) { number += 1 }
        return number
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
