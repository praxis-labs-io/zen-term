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
        XCTAssertEqual(clone.title, "Zen Term c2")
        XCTAssertEqual(
            clone.path, CloneStore.root.appendingPathComponent("zen-term/zen-term-c2", isDirectory: true))
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

    func test_state_countsUncommittedAndUnpushed() throws {
        let clone = try CloneStore.create(from: workspace())
        XCTAssertEqual(CloneStore.state(clone), CloneState(uncommitted: 0, unpushed: 0))

        try write("changed\n", to: clone.path.appendingPathComponent("tracked.txt"))
        try write("new\n", to: clone.path.appendingPathComponent("added.txt"))
        XCTAssertEqual(CloneStore.state(clone), CloneState(uncommitted: 2, unpushed: 0))

        try run(["config", "user.email", "test@example.com"], in: clone.path)
        try run(["config", "user.name", "Test"], in: clone.path)
        try run(["add", "."], in: clone.path)
        try run(["commit", "-m", "work"], in: clone.path)
        XCTAssertEqual(CloneStore.state(clone), CloneState(uncommitted: 0, unpushed: 1))
        XCTAssertFalse(CloneStore.state(clone).isClean)
    }

    // MARK: remove

    func test_remove_deletesTheDirectory() throws {
        let clone = try CloneStore.create(from: workspace())
        try CloneStore.remove(clone)

        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.path.path))
    }

    // MARK: slug

    func test_slug_makesOnePathSegmentFromFreeText() {
        XCTAssertEqual(CloneStore.slug(for: "Zen Term"), "zen-term")
        XCTAssertEqual(CloneStore.slug(for: "web/api"), "web-api")
        XCTAssertEqual(CloneStore.slug(for: "  ../.. "), "workspace")
        XCTAssertEqual(CloneStore.slug(for: "my_repo-1"), "my_repo-1")
    }
}
