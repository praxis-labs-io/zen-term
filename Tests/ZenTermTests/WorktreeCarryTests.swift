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

    /// Every entry in authored order, including the ones that go on to be skipped.
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

    // MARK: what can be carried

    /// The form offers what git ignores, so the candidates come from git rather than a directory
    /// walk. An ignored directory collapses to one entry, which is the granularity carry copies at.
    func test_ignoredEntries_listsIgnoredFilesAndCollapsesIgnoredDirectories() throws {
        try GitFixture.write("SECRET=1\n", to: repo.appendingPathComponent(".env"))
        let build = repo.appendingPathComponent(".build/x", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try GitFixture.write("o\n", to: build.appendingPathComponent("y.o"))

        XCTAssertEqual(WorktreeCarry.ignoredEntries(in: repo), [".build", ".env"])
    }

    /// A Rails `log/` holds a tracked `.keep`, so git cannot collapse it and reports every rotated
    /// log on its own: 170 of craftwork's 249 rows came from one folder. One row instead.
    func test_ignoredEntries_foldsAFolderThatSpraysIgnoredFiles() throws {
        let log = repo.appendingPathComponent("log", isDirectory: true)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        try GitFixture.write("", to: log.appendingPathComponent(".keep"))
        try GitFixture.write("log/*.log\n.env\n", to: repo.appendingPathComponent(".gitignore"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "log"], in: repo)
        try GitFixture.write("a\n", to: log.appendingPathComponent("one.log"))
        try GitFixture.write("b\n", to: log.appendingPathComponent("two.log"))
        try GitFixture.write("S=1\n", to: repo.appendingPathComponent(".env"))

        XCTAssertEqual(WorktreeCarry.ignoredEntries(in: repo), [".env", "log"])
    }

    /// Folding a parent whose ignored children are directories would offer the package folder
    /// itself, hiding the difference between a node_modules worth carrying and a .cache that is not.
    func test_ignoredEntries_doesNotFoldAFolderWhoseChildrenAreDirectories() throws {
        for name in ["pkg/node_modules", "pkg/.turbo"] {
            let dir = repo.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try GitFixture.write("x\n", to: dir.appendingPathComponent("f.txt"))
        }
        try GitFixture.write("index.js\n", to: repo.appendingPathComponent("pkg/index.js"))
        try GitFixture.write("node_modules/\n.turbo/\n", to: repo.appendingPathComponent(".gitignore"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "pkg"], in: repo)

        XCTAssertEqual(
            WorktreeCarry.ignoredEntries(in: repo), ["pkg/.turbo", "pkg/node_modules"])
    }

    /// One ignored file under a folder is already one row. Folding it would rename that row to its
    /// parent and quietly widen what it means.
    func test_ignoredEntries_doesNotFoldASingleFile() throws {
        let config = repo.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try GitFixture.write("x\n", to: config.appendingPathComponent("app.yml"))
        try GitFixture.write("config/*.key\n", to: repo.appendingPathComponent(".gitignore"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "config"], in: repo)
        try GitFixture.write("k\n", to: config.appendingPathComponent("master.key"))

        XCTAssertEqual(WorktreeCarry.ignoredEntries(in: repo), ["config/master.key"])
    }

    /// The whole point of folding: the row has to copy what it says it copies, and leave the
    /// tracked file that stopped git collapsing the folder in the first place.
    func test_copy_ofAPartlyTrackedFolder_bringsTheIgnoredFilesAndLeavesTheTrackedOne() throws {
        let log = repo.appendingPathComponent("log", isDirectory: true)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        try GitFixture.write("keep\n", to: log.appendingPathComponent(".keep"))
        try GitFixture.write("log/*.log\n", to: repo.appendingPathComponent(".gitignore"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "log"], in: repo)
        try GitFixture.write("a\n", to: log.appendingPathComponent("one.log"))
        try GitFixture.run(["worktree", "add", "-b", "side", worktree.path], in: repo)

        let report = WorktreeCarry.copy(["log"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, ["log"])
        XCTAssertEqual(report.skipped, [])
        XCTAssertEqual(
            try String(contentsOf: worktree.appendingPathComponent("log/one.log"), encoding: .utf8),
            "a\n")
        XCTAssertEqual(
            try GitFixture.run(["status", "--porcelain"], in: worktree), "",
            "the tracked .keep is the worktree's own, so the tree stays clean")
    }

    func test_ignoredEntries_listsANestedIgnoredPathOnItsOwn() throws {
        let credentials = repo.appendingPathComponent("config/credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        try GitFixture.write("", to: credentials.appendingPathComponent(".keep"))
        try GitFixture.write(
            ".build/\n.env\nconfig/credentials/*.key\n",
            to: repo.appendingPathComponent(".gitignore"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "config"], in: repo)
        try GitFixture.write("key\n", to: credentials.appendingPathComponent("development.key"))

        XCTAssertEqual(
            WorktreeCarry.ignoredEntries(in: repo), ["config/credentials/development.key"])
    }

    /// A tracked file is refused at copy time, so offering it would be offering a mistake.
    func test_ignoredEntries_leavesOutWhatGitTracks() throws {
        try GitFixture.write("SECRET=1\n", to: repo.appendingPathComponent(".env"))

        XCTAssertEqual(WorktreeCarry.ignoredEntries(in: repo), [".env"])
    }

    /// Nil is not "nothing ignored": the form says it could not ask rather than showing an empty
    /// list that reads as a repo with nothing to carry.
    func test_ignoredEntries_isNilWhenTheFolderIsNotARepo() {
        XCTAssertNil(WorktreeCarry.ignoredEntries(in: root))
    }

    // MARK: nested entries

    /// A Rails app keeps its dev key at `config/credentials/development.key`, under a directory
    /// git already tracks, so the worktree has the parent and only the file has to come across.
    func test_copy_bringsANestedEntryUnderAParentTheWorktreeHas() throws {
        let credentials = repo.appendingPathComponent("config/credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        try GitFixture.write("", to: credentials.appendingPathComponent(".keep"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "config"], in: repo)
        try GitFixture.write("key\n", to: credentials.appendingPathComponent("development.key"))
        try GitFixture.run(["worktree", "add", "-b", "side", worktree.path], in: repo)

        let report = WorktreeCarry.copy(
            ["config/credentials/development.key"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, ["config/credentials/development.key"])
        XCTAssertEqual(report.skipped, [])
        XCTAssertEqual(
            try String(
                contentsOf: worktree.appendingPathComponent("config/credentials/development.key"),
                encoding: .utf8),
            "key\n")
    }

    /// The whole directory is gitignored, so the worktree has no parent to copy into. Nothing used
    /// to make one, and `copyfile` died with an `ENOENT` that read as a missing source.
    func test_copy_createsTheParentTheWorktreeDoesNotHave() throws {
        let claude = repo.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try GitFixture.write("{}\n", to: claude.appendingPathComponent("settings.local.json"))
        try GitFixture.run(["worktree", "add", "-b", "side", worktree.path], in: repo)
        XCTAssertFalse(GitFixture.exists(worktree.appendingPathComponent(".claude")))

        let report = WorktreeCarry.copy(
            [".claude/settings.local.json"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, [".claude/settings.local.json"])
        XCTAssertEqual(report.skipped, [])
        XCTAssertEqual(
            try String(
                contentsOf: worktree.appendingPathComponent(".claude/settings.local.json"),
                encoding: .utf8),
            "{}\n")
    }

    func test_copy_refusesANestedPathGitTracks() throws {
        let config = repo.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try GitFixture.write("a: 1\n", to: config.appendingPathComponent("database.yml"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "config"], in: repo)
        try GitFixture.run(["worktree", "add", "-b", "side", worktree.path], in: repo)

        let report = WorktreeCarry.copy(["config/database.yml"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, [])
        XCTAssertEqual(
            report.skipped,
            [CarryReport.Skipped(name: "config/database.yml", reason: .tracked)])
    }

    func test_copy_refusesANestedEntryThatClimbsOut() throws {
        let bystander = root.appendingPathComponent("bystander.txt")
        try GitFixture.write("untouched\n", to: bystander)

        let report = WorktreeCarry.copy(
            ["config/../../bystander.txt"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, [])
        XCTAssertEqual(
            report.skipped,
            [CarryReport.Skipped(name: "config/../../bystander.txt", reason: .leavesTheWorkspace)])
        XCTAssertEqual(try String(contentsOf: bystander, encoding: .utf8), "untouched\n")
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
