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
        try write(".build/\n.env\n", to: work.appendingPathComponent(".gitignore"))
        try run(["add", "."], in: work)
        try run(["commit", "-m", "first"], in: work)
        try run(["remote", "add", "origin", origin.path], in: work)
        try run(["push", "-u", "origin", "main"], in: work)
        return work
    }

    private func workspace(title: String = "Zen Term") -> Workspace {
        Workspace(title: title, path: repo, main: nil, right: nil, bottom: nil, focus: .main, env: [:])
    }

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
    func test_create_stripsTheParentsBuildCache() throws {
        let cache = repo.appendingPathComponent(".build", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try write("warm\n", to: cache.appendingPathComponent("artifact"))

        let clone = try CloneStore.create(from: workspace())

        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.path.appendingPathComponent(".build").path))
        // The parent's own cache is untouched — only the copy inside the clone is stripped.
        XCTAssertEqual(read(cache.appendingPathComponent("artifact")), "warm\n")
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
