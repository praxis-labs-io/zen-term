import XCTest

@testable import ZenTerm

final class CloneStoreTests: XCTestCase {
    private var root: URL!
    private var repo: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clone-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        CloneStore.rootOverrideForTesting = root.appendingPathComponent("clones", isDirectory: true)
        repo = try makeRepoWithOrigin()
    }

    override func tearDownWithError() throws {
        CloneStore.rootOverrideForTesting = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: fixtures

    /// A working repo on `main`, pushed to a bare `origin` beside it.
    private func makeRepoWithOrigin() throws -> URL {
        let origin = root.appendingPathComponent("origin.git", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)

        try run(["init", "--bare", "--initial-branch=main"], in: origin)
        try run(["init", "--initial-branch=main"], in: work)
        try run(["config", "user.email", "test@example.com"], in: work)
        try run(["config", "user.name", "Test"], in: work)
        try write("one\n", to: work.appendingPathComponent("tracked.txt"))
        try write(
            ".build/\n.env\nvenv311/\n.turbo/\nbig-cache/\n",
            to: work.appendingPathComponent(".gitignore"))
        try run(["add", "."], in: work)
        try run(["commit", "-m", "first"], in: work)
        try run(["remote", "add", "origin", origin.path], in: work)
        try run(["push", "-u", "origin", "main"], in: work)
        return work
    }

    private func workspace(title: String = "Zen Term", cloneExclude: [String] = []) -> Workspace {
        Workspace(
            title: title, path: repo, main: nil, right: nil, bottom: nil, focus: .main, env: [:],
            cloneExclude: cloneExclude)
    }

    /// A directory in the parent carrying `marker`, the way a virtualenv carries `pyvenv.cfg`.
    @discardableResult
    private func makeDirectory(_ name: String, marker: String? = nil, payload: String = "payload\n")
        throws -> URL
    {
        let dir = repo.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let marker { try write("", to: dir.appendingPathComponent(marker)) }
        try write(payload, to: dir.appendingPathComponent("content"))
        return dir
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @discardableResult
    private func run(_ args: [String], in dir: URL) throws -> String {
        try GitCommand.run(args, in: dir).get()
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    // MARK: create

    func test_create_landsOnBranchOffOriginMain() throws {
        let clone = try CloneStore.create(from: workspace())

        XCTAssertEqual(clone.name, "c2")
        XCTAssertEqual(clone.branch, "main")
        XCTAssertEqual(clone.title, "Zen Term c2", "the label follows the workspace's title")
        // The path follows the workspace's *folder*, under a directory keyed on its full path.
        let group = CloneStore.directoryName(for: workspace())
        XCTAssertEqual(
            clone.path,
            CloneStore.root.appendingPathComponent("\(group)/work-c2", isDirectory: true))
        XCTAssertTrue(group.hasPrefix("work-"), "readable folder name, then the path digest")
        XCTAssertEqual(try run(["rev-parse", "--abbrev-ref", "HEAD"], in: clone.path), "main")
        XCTAssertEqual(
            try run(["rev-parse", "HEAD"], in: clone.path),
            try run(["rev-parse", "origin/main"], in: repo))
    }

    func test_create_dropsParentEdits_keepsIgnoredFiles() throws {
        try write("edited\n", to: repo.appendingPathComponent("tracked.txt"))
        try write("secret\n", to: repo.appendingPathComponent(".env"))

        let clone = try CloneStore.create(from: workspace())

        XCTAssertEqual(read(clone.path.appendingPathComponent("tracked.txt")), "one\n")
        XCTAssertEqual(
            read(clone.path.appendingPathComponent(".env")), "secret\n",
            "a gitignored file a local setup needs (.env, node_modules, …) rides along")
        // The parent keeps its own edit: the force checkout happens inside the copy.
        XCTAssertEqual(read(repo.appendingPathComponent("tracked.txt")), "edited\n")
    }

    func test_create_dropsPlainUntrackedFiles() throws {
        try write("scratch\n", to: repo.appendingPathComponent("scratch.txt"))

        let clone = try CloneStore.create(from: workspace())

        XCTAssertNil(
            read(clone.path.appendingPathComponent("scratch.txt")),
            "unlike a gitignored file, something never told to git at all doesn't ride along")
    }

    /// A relocated `.build/` doesn't degrade to a cold rebuild, it fails outright: Clang's module
    /// cache and PCH validation hard-error on a path that no longer matches where they were built.
    func test_create_stripsASwiftBuildDirectory() throws {
        let cache = try makeDirectory(".build", marker: "build.db", payload: "warm\n")

        let clone = try CloneStore.create(from: workspace())

        XCTAssertFalse(exists(clone.path.appendingPathComponent(".build")))
        // The parent's own cache is untouched — only the copy inside the clone is stripped.
        XCTAssertEqual(read(cache.appendingPathComponent("content")), "warm\n")
    }

    /// Recognized by `pyvenv.cfg`, not by the name `venv`: a relocated virtualenv has a dangling
    /// `bin/python3` and a `pip3` that dies with "bad interpreter", whatever its directory is called.
    func test_create_stripsAVirtualenvUnderAnyName() throws {
        try makeDirectory("venv311", marker: "pyvenv.cfg")

        let clone = try CloneStore.create(from: workspace())

        XCTAssertFalse(exists(clone.path.appendingPathComponent("venv311")))
    }

    /// The counterweight to the two above, and the reason the marker list stays short: these
    /// survive relocation, and carrying them is what makes a clone worth making. A `.turbo` cache
    /// turns a 33s first build into 1.5s, so stripping it would spend the whole feature.
    func test_create_keepsIgnoredCachesThatSurviveRelocation() throws {
        try makeDirectory(".turbo")
        try makeDirectory("big-cache")

        let clone = try CloneStore.create(from: workspace())

        XCTAssertTrue(exists(clone.path.appendingPathComponent(".turbo/content")))
        XCTAssertTrue(exists(clone.path.appendingPathComponent("big-cache/content")))
    }

    /// `build.db` is an ordinary enough filename that a tracked directory can hold one. Stripping
    /// it would delete content the force checkout had just restored, so detection is gated on git
    /// actually ignoring the directory.
    func test_create_keepsATrackedDirectoryCarryingAMarkerFile() throws {
        try makeDirectory("data", marker: "build.db")
        try run(["add", "."], in: repo)
        try run(["commit", "-m", "tracked data"], in: repo)
        try run(["push"], in: repo)

        let clone = try CloneStore.create(from: workspace())

        XCTAssertTrue(exists(clone.path.appendingPathComponent("data/build.db")))
        XCTAssertTrue(exists(clone.path.appendingPathComponent("data/content")))
    }

    // MARK: clone_exclude

    func test_create_dropsWhatCloneExcludeNames() throws {
        try makeDirectory("big-cache")
        try makeDirectory(".turbo")

        let clone = try CloneStore.create(from: workspace(cloneExclude: ["big-cache"]))

        XCTAssertFalse(exists(clone.path.appendingPathComponent("big-cache")))
        XCTAssertTrue(exists(clone.path.appendingPathComponent(".turbo")), "only what was named")
        XCTAssertTrue(exists(repo.appendingPathComponent("big-cache")), "the parent keeps its own")
    }

    /// The clone is deleted wholesale later, so an entry pointing outside it would aim that delete
    /// somewhere else. The parser refuses these; this is the guard where the delete happens.
    ///
    /// The targets have to sit where the escape actually resolves — beside the clone, not beside
    /// the repo — or the entries land on nothing and the test passes with the guard removed. `..`
    /// is the sharp one: unguarded it deletes the directory holding every clone of this workspace.
    func test_create_ignoresACloneExcludeThatLeavesTheWorkspace() throws {
        let neighbour = try CloneStore.create(from: workspace())
        let bystander = neighbour.path.deletingLastPathComponent()
            .appendingPathComponent("bystander", isDirectory: true)
        try FileManager.default.createDirectory(at: bystander, withIntermediateDirectories: true)
        try write("safe\n", to: bystander.appendingPathComponent("content"))

        let clone = try CloneStore.create(
            from: workspace(cloneExclude: ["../bystander", "..", "../\(neighbour.path.lastPathComponent)"]))

        XCTAssertEqual(read(bystander.appendingPathComponent("content")), "safe\n")
        XCTAssertTrue(exists(neighbour.path.appendingPathComponent("tracked.txt")), "a sibling clone survives")
        XCTAssertTrue(exists(clone.path.appendingPathComponent("tracked.txt")), "and so does this one")
    }

    func test_create_toleratesACloneExcludeNamingSomethingAbsent() throws {
        let clone = try CloneStore.create(from: workspace(cloneExclude: ["never-existed"]))

        XCTAssertTrue(exists(clone.path))
    }

    func test_create_numbersFromTwoAndSkipsTaken() throws {
        let first = try CloneStore.create(from: workspace())
        let second = try CloneStore.create(from: workspace())
        try CloneStore.remove(first)
        let third = try CloneStore.create(from: workspace())

        XCTAssertEqual([first.name, second.name, third.name], ["c2", "c3", "c2"])
    }

    func test_create_rejectsANonRepo() throws {
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let ws = Workspace(
            title: "Plain", path: plain, main: nil, right: nil, bottom: nil, focus: .main, env: [:])

        XCTAssertThrowsError(try CloneStore.create(from: ws)) { error in
            XCTAssertEqual(error as? CloneStore.CloneError, .notARepo(plain.standardizedFileURL))
        }
    }

    func test_create_rejectsARepoWithNoOriginMain_andLeavesNothingBehind() throws {
        try run(["remote", "remove", "origin"], in: repo)
        try run(["update-ref", "-d", "refs/remotes/origin/main"], in: repo)

        XCTAssertThrowsError(try CloneStore.create(from: workspace())) { error in
            XCTAssertEqual(error as? CloneStore.CloneError, .noBaseBranch)
        }
        XCTAssertTrue(CloneStore.list(for: [workspace()]).isEmpty)
    }

    /// Two clones started at once, which is one double-tap of ⌥⏎. Both scan the directory, both
    /// see no `c2`, and the loser's `clonefile` fails with EEXIST — reported as "File exists",
    /// which tells the person nothing about what they did.
    func test_create_concurrentClonesGetDistinctNumbers() throws {
        let ws = workspace()
        let done = expectation(description: "both clones finish")
        done.expectedFulfillmentCount = 2
        var results: [Result<Clone, Error>] = []
        let lock = NSLock()

        for _ in 0..<2 {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try CloneStore.create(from: ws) }
                lock.lock()
                results.append(result)
                lock.unlock()
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 60)

        let clones = results.compactMap { try? $0.get() }
        XCTAssertEqual(clones.count, 2, "neither attempt loses a race to the other")
        XCTAssertEqual(Set(clones.map(\.name)).count, 2, "and they get different numbers")
        XCTAssertEqual(Set(CloneStore.list(for: [ws]).map(\.path)).count, 2)
    }

    // MARK: list

    func test_list_findsClonesInOrder_andIgnoresStrangers() throws {
        let first = try CloneStore.create(from: workspace())
        let second = try CloneStore.create(from: workspace())
        try FileManager.default.createDirectory(
            at: CloneStore.root.appendingPathComponent("zen-term/notes", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: CloneStore.root.appendingPathComponent("someone-else/2", isDirectory: true),
            withIntermediateDirectories: true)

        XCTAssertEqual(CloneStore.list(for: [workspace()]), [first, second])
    }

    func test_list_forgetsACloneDeletedByHand() throws {
        let clone = try CloneStore.create(from: workspace())
        // A person deletes the whole "c2" folder, not just the checkout nested inside it.
        try FileManager.default.removeItem(at: clone.path.deletingLastPathComponent())

        XCTAssertTrue(CloneStore.list(for: [workspace()]).isEmpty)
    }

    // MARK: state

    /// A clone is a copy of the whole `.git`, so it inherits the parent's local branches and
    /// stashes. Counting those would mark every brand-new clone as dirty, and a confirm that always
    /// warns is one people stop reading — which is how the real warning gets clicked through.
    func test_state_ignoresBranchesAndStashesInheritedFromTheParent() throws {
        try run(["checkout", "-b", "feature/parent-work"], in: repo)
        try write("parent\n", to: repo.appendingPathComponent("parent.txt"))
        try run(["add", "."], in: repo)
        try run(["commit", "-m", "the parent's own unpushed work"], in: repo)
        try run(["checkout", "main"], in: repo)
        try write("scratch\n", to: repo.appendingPathComponent("tracked.txt"))
        try run(["stash"], in: repo)

        let clone = try CloneStore.create(from: workspace())

        XCTAssertEqual(CloneStore.state(clone), CloneState(uncommitted: 0, unpushed: 0, stashed: 0))
        XCTAssertEqual(CloneStore.state(clone)?.isClean, true, "a clone nobody has touched is clean")
        // The branch is inherited, not discarded: a lane can pick it up.
        XCTAssertTrue(
            try run(["branch", "--list", "feature/parent-work"], in: clone.path).contains("feature/parent-work"),
            "the inherited branch is still there to work on")
    }

    /// Inherited work is not counted, but *extending* it in the clone is this clone's work.
    func test_state_countsCommitsAddedOntoAnInheritedBranch() throws {
        try run(["checkout", "-b", "feature/parent-work"], in: repo)
        try write("parent\n", to: repo.appendingPathComponent("parent.txt"))
        try run(["add", "."], in: repo)
        try run(["commit", "-m", "the parent's own unpushed work"], in: repo)
        try run(["checkout", "main"], in: repo)

        let clone = try CloneStore.create(from: workspace())
        try run(["config", "user.email", "test@example.com"], in: clone.path)
        try run(["config", "user.name", "Test"], in: clone.path)
        try run(["checkout", "feature/parent-work"], in: clone.path)
        try write("more\n", to: clone.path.appendingPathComponent("more.txt"))
        try run(["add", "."], in: clone.path)
        try run(["commit", "-m", "extending it here"], in: clone.path)

        XCTAssertEqual(CloneStore.state(clone)?.unpushed, 1, "the new commit counts, the inherited one does not")
    }

    /// The baseline namespace is cleared before it is rewritten, and that is not tidiness: git
    /// refuses to hold refs at both `refs/zenterm-base/feature` and `refs/zenterm-base/feature/x`.
    /// A stale inherited ref whose name has since become a path prefix makes `update-ref` fail,
    /// which fails the whole clone and rolls it back.
    func test_create_survivesAnInheritedBaselineWhoseNameBecameAPathPrefix() throws {
        try run(["branch", "feature"], in: repo)

        let first = try CloneStore.create(from: workspace())
        // In the clone, the plain branch goes and a nested one takes its name as a prefix.
        try run(["branch", "-D", "feature"], in: first.path)
        try run(["branch", "feature/x"], in: first.path)

        let second = try CloneStore.create(
            from: Workspace(
                title: "Zen Term", path: first.path, main: nil, right: nil, bottom: nil, focus: .main,
                env: [:]))

        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path.path))
        XCTAssertEqual(CloneStore.state(second)?.isClean, true)
    }

    /// A clone of a clone must measure against its own start, not the one it inherited.
    func test_state_ofACloneOfAClone_measuresAgainstItsOwnBaseline() throws {
        let first = try CloneStore.create(from: workspace())
        try run(["config", "user.email", "test@example.com"], in: first.path)
        try run(["config", "user.name", "Test"], in: first.path)
        try run(["checkout", "-b", "feature/in-the-first-clone"], in: first.path)
        try write("work\n", to: first.path.appendingPathComponent("work.txt"))
        try run(["add", "."], in: first.path)
        try run(["commit", "-m", "work in the first clone"], in: first.path)
        try run(["checkout", "main"], in: first.path)
        XCTAssertEqual(CloneStore.state(first)?.unpushed, 1)

        let second = try CloneStore.create(
            from: Workspace(
                title: "Zen Term", path: first.path, main: nil, right: nil, bottom: nil, focus: .main,
                env: [:]))

        XCTAssertEqual(
            CloneStore.state(second)?.unpushed, 0,
            "the second clone starts fresh; the first clone's work is inherited, not its own")
    }

    /// Nil is "we could not read it", and the caller must not be able to mistake that for clean.
    func test_state_isNilWhenTheCloneCannotBeRead() throws {
        let clone = try CloneStore.create(from: workspace())
        try FileManager.default.removeItem(at: clone.path.appendingPathComponent(".git"))

        XCTAssertNil(CloneStore.state(clone), "a repo we cannot inspect never reports as clean")
    }

    /// The failure this guards is the worst one this feature can have: the confirm saying the clone
    /// has nothing uncommitted, immediately before deleting a day of work. Counting only HEAD's
    /// unpushed commits does exactly that whenever the work is parked on a branch you are not on.
    func test_state_countsCommitsOnABranchYouAreNotStandingOn() throws {
        let clone = try CloneStore.create(from: workspace())
        try run(["config", "user.email", "test@example.com"], in: clone.path)
        try run(["config", "user.name", "Test"], in: clone.path)

        try run(["checkout", "-b", "feature/side"], in: clone.path)
        try write("work\n", to: clone.path.appendingPathComponent("side.txt"))
        try run(["add", "."], in: clone.path)
        try run(["commit", "-m", "a day of work"], in: clone.path)
        try run(["checkout", "main"], in: clone.path)

        // From main, `git status` is clean and HEAD has nothing unpushed. The work is still there.
        XCTAssertEqual(CloneStore.state(clone)?.unpushed, 1)
        XCTAssertEqual(
            CloneStore.state(clone)?.isClean, false, "so the clone must not read as safe to delete")
    }

    /// A stash lives in `refs/stash`, which is outside `--branches` as well as HEAD.
    func test_state_countsStashedWork() throws {
        let clone = try CloneStore.create(from: workspace())
        try run(["config", "user.email", "test@example.com"], in: clone.path)
        try run(["config", "user.name", "Test"], in: clone.path)

        try write("scratch\n", to: clone.path.appendingPathComponent("tracked.txt"))
        try run(["stash"], in: clone.path)

        XCTAssertEqual(CloneStore.state(clone)?.uncommitted, 0, "stashing cleans the working tree")
        XCTAssertEqual(CloneStore.state(clone)?.stashed, 1)
        XCTAssertEqual(CloneStore.state(clone)?.isClean, false)
    }

    func test_state_countsUncommittedAndUnpushed() throws {
        let clone = try CloneStore.create(from: workspace())
        XCTAssertEqual(CloneStore.state(clone), CloneState(uncommitted: 0, unpushed: 0, stashed: 0))

        try write("changed\n", to: clone.path.appendingPathComponent("tracked.txt"))
        try write("new\n", to: clone.path.appendingPathComponent("added.txt"))
        XCTAssertEqual(CloneStore.state(clone), CloneState(uncommitted: 2, unpushed: 0, stashed: 0))

        try run(["config", "user.email", "test@example.com"], in: clone.path)
        try run(["config", "user.name", "Test"], in: clone.path)
        try run(["add", "."], in: clone.path)
        try run(["commit", "-m", "work"], in: clone.path)
        XCTAssertEqual(CloneStore.state(clone), CloneState(uncommitted: 0, unpushed: 1, stashed: 0))
        XCTAssertEqual(CloneStore.state(clone)?.isClean, false)
    }

    // MARK: remove

    func test_remove_deletesTheDirectory() throws {
        let clone = try CloneStore.create(from: workspace())
        try CloneStore.remove(clone)

        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.path.path))
    }

    // MARK: slug

    func test_slug_makesOnePathSegmentFromFreeText() {
        XCTAssertEqual(CloneStore.slug(forText: "Zen Term"), "zen-term")
        XCTAssertEqual(CloneStore.slug(forText: "web/api"), "web-api")
        XCTAssertEqual(CloneStore.slug(forText: "  ../.. "), "workspace")
        XCTAssertEqual(CloneStore.slug(forText: "my_repo-1"), "my_repo-1")
    }

    // MARK: which directory a workspace's clones live in

    private func workspace(title: String, at path: URL) -> Workspace {
        Workspace(
            title: title, path: path, main: nil, right: nil, bottom: nil, focus: .main, env: [:])
    }

    /// `slug` folds case and punctuation, and `WorkspacesWriter` only refuses an exact duplicate
    /// title. Keyed on the title, "Zen Term" and "zen term" would share a clones directory: each
    /// would list the other's clones, and ⌥⌫ on either would delete both.
    func test_directoryName_differsForWorkspacesWhoseTitlesSlugTheSame() {
        let first = workspace(title: "Zen Term", at: URL(fileURLWithPath: "/Users/x/Dev/zen-term"))
        let second = workspace(title: "zen term", at: URL(fileURLWithPath: "/Users/x/work/zen-term"))

        XCTAssertNotEqual(CloneStore.directoryName(for: first), CloneStore.directoryName(for: second))
    }

    /// The readable half comes from the folder, so both still say what they are.
    func test_directoryName_keepsTheFolderNameReadable() {
        let ws = workspace(title: "Anything At All", at: URL(fileURLWithPath: "/Users/x/Dev/zen-term"))

        XCTAssertTrue(CloneStore.directoryName(for: ws).hasPrefix("zen-term-"))
        XCTAssertEqual(CloneStore.slug(for: ws), "zen-term")
    }

    /// The title is a label. Renaming a workspace used to orphan every clone it had, because the
    /// directory was named after the old title and nothing went looking under it again.
    func test_renamingAWorkspace_keepsItsClones() throws {
        let clone = try CloneStore.create(from: workspace(title: "Zen Term"))

        let renamed = Workspace(
            title: "ZenTerm (main)", path: repo, main: nil, right: nil, bottom: nil, focus: .main,
            env: [:])
        let listed = CloneStore.list(for: [renamed])

        XCTAssertEqual(listed.map(\.path), [clone.path], "the same clone on disk")
        XCTAssertEqual(listed.first?.title, "ZenTerm (main) c2", "relabelled to the new title")
    }

    /// Two workspaces at different paths never see each other's clones, however alike they read.
    func test_list_doesNotLeakClonesBetweenLookalikeWorkspaces() throws {
        let other = root.appendingPathComponent("other-checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let lookalike = workspace(title: "zen term", at: other)

        _ = try CloneStore.create(from: workspace(title: "Zen Term"))

        XCTAssertTrue(CloneStore.list(for: [lookalike]).isEmpty)
        XCTAssertEqual(CloneStore.list(for: [workspace(title: "Zen Term")]).count, 1)
    }
}
