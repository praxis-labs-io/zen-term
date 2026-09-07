import XCTest

@testable import ZenTerm

/// The carry step, over real repos on disk. Every claim about `copyfile` here was probed on
/// macOS 25.5 before the code leaned on it, because the flags do not behave uniformly: a clone
/// onto an existing *file* fails, and onto an existing *directory* succeeds having copied nothing.
final class WorktreeCarryTests: XCTestCase {
    private var root: URL!
    private var repo: URL!
    private var worktree: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worktree-carry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // `.gitignore` here already carries `.build/` and `.env`.
        repo = try GitFixture.makeRepo(at: root.appendingPathComponent("work", isDirectory: true))
        worktree = root.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: what comes across

    /// The create card names the entry it is on, so `onEntry` has to fire for every entry in
    /// authored order, including the ones that go on to be skipped.
    func test_copy_namesEveryEntryAsItStarts() throws {
        try GitFixture.write("SECRET=1\n", to: repo.appendingPathComponent(".env"))

        var seen: [String] = []
        let report = WorktreeCarry.copy(
            [".env", "missing"], from: repo, into: worktree, onEntry: { seen.append($0) })

        XCTAssertEqual(seen, [".env", "missing"])
        XCTAssertEqual(report.carried, [".env"])
    }

    func test_copy_bringsAnIgnoredFile() throws {
        try GitFixture.write("SECRET=1\n", to: repo.appendingPathComponent(".env"))

        let report = WorktreeCarry.copy([".env"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, [".env"])
        XCTAssertEqual(report.skipped, [])
        XCTAssertEqual(
            try String(contentsOf: worktree.appendingPathComponent(".env"), encoding: .utf8),
            "SECRET=1\n")
    }

    func test_copy_bringsAnIgnoredDirectoryAndItsContents() throws {
        let nested = repo.appendingPathComponent("node_modules/pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try GitFixture.write("{}\n", to: nested.appendingPathComponent("package.json"))

        let report = WorktreeCarry.copy(["node_modules"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, ["node_modules"])
        XCTAssertEqual(
            try String(
                contentsOf: worktree.appendingPathComponent("node_modules/pkg/package.json"),
                encoding: .utf8), "{}\n")
    }

    /// A pnpm `node_modules` is mostly symlinks. `COPYFILE_CLONE` implies `COPYFILE_NOFOLLOW_SRC`,
    /// so the link is cloned rather than the tree it points at, which is what keeps the copy cheap.
    func test_copy_bringsASymlinkAsASymlinkRatherThanItsTarget() throws {
        let store = repo.appendingPathComponent("node_modules/.store", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try GitFixture.write("real\n", to: store.appendingPathComponent("real.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent("node_modules/link.txt").path,
            withDestinationPath: ".store/real.txt")

        XCTAssertEqual(
            WorktreeCarry.copy(["node_modules"], from: repo, into: worktree).carried,
            ["node_modules"])

        let link = worktree.appendingPathComponent("node_modules/link.txt").path
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: link)[.type] as? FileAttributeType,
            .typeSymbolicLink, "the link itself has to come across, not what it points at")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link), ".store/real.txt")
    }

    func test_copy_carriesTheRestWhenOneEntryIsSkipped() throws {
        try GitFixture.write("SECRET=1\n", to: repo.appendingPathComponent(".env"))

        let report = WorktreeCarry.copy([".env", "absent", ".env"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, [".env"], "the third repeats the first, which now exists")
        XCTAssertEqual(
            report.skipped,
            [
                CarryReport.Skipped(name: "absent", reason: .notThere),
                CarryReport.Skipped(name: ".env", reason: .alreadyInTheWorktree),
            ])
    }

    // MARK: what it refuses, and what it leaves alone

    func test_copy_reportsAnEntryThatIsNotThere() {
        let report = WorktreeCarry.copy(["node_modules"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, [])
        XCTAssertEqual(
            report.skipped, [CarryReport.Skipped(name: "node_modules", reason: .notThere)])
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: worktree.path), [])
    }

    /// Carrying a tracked path leaves git reporting a modification that never goes away, which is
    /// the whole reason the check exists. `tracked.txt` is committed by the fixture.
    func test_copy_refusesATrackedPath() throws {
        try GitFixture.write("edited\n", to: repo.appendingPathComponent("tracked.txt"))
        try GitFixture.run(["worktree", "add", "-b", "side", worktree.path], in: repo)

        let report = WorktreeCarry.copy(["tracked.txt"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, [])
        XCTAssertEqual(
            report.skipped, [CarryReport.Skipped(name: "tracked.txt", reason: .tracked)])
        XCTAssertEqual(
            try GitFixture.run(["status", "--porcelain"], in: worktree), "",
            "the worktree has to still be clean, which is what refusing a tracked path buys")
    }

    func test_copy_refusesAnEntryThatLeavesTheWorkspace() throws {
        let bystander = root.appendingPathComponent("bystander.txt")
        try GitFixture.write("untouched\n", to: bystander)

        let report = WorktreeCarry.copy(["../bystander.txt"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, [])
        XCTAssertEqual(
            report.skipped,
            [CarryReport.Skipped(name: "../bystander.txt", reason: .leavesTheWorkspace)])
        XCTAssertEqual(try String(contentsOf: bystander, encoding: .utf8), "untouched\n")
    }

    /// Probed: `fileExists` follows links, so a dangling one reads as absent. `copyfile` then fails
    /// `EEXIST` and the cleanup would delete an entry the worktree already had.
    func test_copy_leavesADanglingSymlinkTheWorktreeAlreadyHas() throws {
        let source = repo.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try GitFixture.write("new\n", to: source.appendingPathComponent("fresh.txt"))
        let existing = worktree.appendingPathComponent("node_modules")
        try FileManager.default.createSymbolicLink(
            atPath: existing.path, withDestinationPath: "../gone")

        let report = WorktreeCarry.copy(["node_modules"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, [])
        XCTAssertEqual(
            report.skipped,
            [CarryReport.Skipped(name: "node_modules", reason: .alreadyInTheWorktree)])
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: existing.path), "../gone")
    }

    /// `--` ends option parsing but not pathspec globbing, so without `--literal-pathspecs` this
    /// matches the fixture's tracked `tracked.txt` and is refused as tracked.
    func test_copy_doesNotTreatAGlobAsAMatchOnTrackedFiles() throws {
        try GitFixture.write("ignored\n", to: repo.appendingPathComponent("*.txt"))

        let report = WorktreeCarry.copy(["*.txt"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, ["*.txt"])
        XCTAssertEqual(report.skipped, [])
    }

    /// `COPYFILE_CLONE` implies `COPYFILE_NOFOLLOW_SRC`, so this arrives as a link holding its
    /// original relative target. A worktree sits under a different parent, so it would dangle.
    func test_copy_refusesASymlinkPointingOutsideTheWorkspace() throws {
        let outside = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try GitFixture.write("secret\n", to: outside.appendingPathComponent(".env"))
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent(".env").path, withDestinationPath: "../shared/.env")

        let report = WorktreeCarry.copy([".env"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, [])
        XCTAssertEqual(
            report.skipped, [CarryReport.Skipped(name: ".env", reason: .leavesTheWorkspace)])
        XCTAssertFalse(GitFixture.exists(worktree.appendingPathComponent(".env")))
    }

    /// Probed: `copyfile` with `COPYFILE_CLONE` returns 0 for a directory that already exists,
    /// having copied none of it. Trusting that would report an entry as carried when it was not.
    func test_copy_refusesAnEntryTheWorktreeAlreadyHas() throws {
        let source = repo.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try GitFixture.write("new\n", to: source.appendingPathComponent("fresh.txt"))
        let existing = worktree.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try GitFixture.write("old\n", to: existing.appendingPathComponent("stale.txt"))

        let report = WorktreeCarry.copy(["node_modules"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, [])
        XCTAssertEqual(
            report.skipped,
            [CarryReport.Skipped(name: "node_modules", reason: .alreadyInTheWorktree)])
        XCTAssertFalse(GitFixture.exists(existing.appendingPathComponent("fresh.txt")))
        XCTAssertTrue(GitFixture.exists(existing.appendingPathComponent("stale.txt")))
    }

    /// A recursive copy can die partway through, and half a `node_modules` reads to a package
    /// manager as an install it need not redo. An unreadable member is how that is reproduced.
    func test_copy_removesAPartialEntryWhenTheCopyFails() throws {
        let source = repo.appendingPathComponent("node_modules/pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try GitFixture.write("readable\n", to: source.appendingPathComponent("fine.txt"))
        let locked = source.appendingPathComponent("locked.txt")
        try GitFixture.write("locked\n", to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: locked.path)
        }

        let report = WorktreeCarry.copy(["node_modules"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, [])
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertEqual(report.skipped.first?.name, "node_modules")
        if case .copyFailed = report.skipped.first?.reason {
        } else {
            XCTFail("expected a copyFailed reason, got \(String(describing: report.skipped.first))")
        }
        XCTAssertFalse(
            GitFixture.exists(worktree.appendingPathComponent("node_modules")),
            "a half-copied entry has to be taken back, not left for a package manager to find")
    }
}
