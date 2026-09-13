import XCTest

@testable import ZenTerm

final class WorktreeCarryTests: XCTestCase {
    private var root: URL!
    private var repo: URL!
    private var worktree: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worktree-carry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = try GitFixture.makeRepo(at: root.appendingPathComponent("work", isDirectory: true))
        worktree = root.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

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

    func test_ignoredEntries_listsIgnoredFilesAndCollapsesIgnoredDirectories() throws {
        try GitFixture.write("SECRET=1\n", to: repo.appendingPathComponent(".env"))
        let build = repo.appendingPathComponent(".build/x", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try GitFixture.write("o\n", to: build.appendingPathComponent("y.o"))

        XCTAssertEqual(
            WorktreeCarry.ignoredEntries(in: repo, chosen: [])?.resting, [".build", ".env"])
    }

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

        XCTAssertEqual(WorktreeCarry.ignoredEntries(in: repo, chosen: [])?.resting, [".env", "log"])
    }

    func test_ignoredEntries_areRelativeToTheWorkspace_notTheRepoRoot() throws {
        let web = repo.appendingPathComponent("pkg/web/node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try GitFixture.write("x\n", to: repo.appendingPathComponent("pkg/web/index.js"))
        try GitFixture.write("node_modules/\n", to: repo.appendingPathComponent(".gitignore"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "pkg"], in: repo)
        try GitFixture.write("{}\n", to: web.appendingPathComponent("p.json"))

        let workspace = repo.appendingPathComponent("pkg/web", isDirectory: true)
        let catalog = try XCTUnwrap(WorktreeCarry.ignoredEntries(in: workspace, chosen: []))

        XCTAssertEqual(catalog.resting, ["node_modules"])
    }

    func test_copy_ofATrackedFolderWithNothingIgnoredInIt_saysNothingIsThere() throws {
        let src = repo.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try GitFixture.write("x\n", to: src.appendingPathComponent("main.swift"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "src"], in: repo)
        try GitFixture.run(["worktree", "add", "-b", "side", worktree.path], in: repo)

        let report = WorktreeCarry.copy(["src"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, [])
        XCTAssertEqual(report.skipped, [CarryReport.Skipped(name: "src", reason: .notThere)])
    }

    func test_copy_refusesToWriteThroughASymlinkedParentInTheWorktree() throws {
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let config = repo.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try GitFixture.write("k\n", to: config.appendingPathComponent(".keep"))
        try GitFixture.write("config/*.secret\n", to: repo.appendingPathComponent(".gitignore"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "config"], in: repo)
        try GitFixture.write("S\n", to: config.appendingPathComponent("a.secret"))
        try GitFixture.run(["worktree", "add", "-b", "side", worktree.path], in: repo)
        try FileManager.default.removeItem(at: worktree.appendingPathComponent("config"))
        try FileManager.default.createSymbolicLink(
            at: worktree.appendingPathComponent("config"), withDestinationURL: outside)

        let report = WorktreeCarry.copy(["config"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, [])
        XCTAssertEqual(
            report.skipped, [CarryReport.Skipped(name: "config", reason: .leavesTheWorkspace)])
        XCTAssertFalse(
            GitFixture.exists(outside.appendingPathComponent("a.secret")),
            "nothing may be written through the link")
    }

    func test_copy_ofAPartlyTrackedFolder_refusesASymlinkPointingOut() throws {
        let bystander = root.appendingPathComponent("bystander.txt")
        try GitFixture.write("untouched\n", to: bystander)
        let config = repo.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try GitFixture.write("k\n", to: config.appendingPathComponent(".keep"))
        try GitFixture.write("config/*.link\n", to: repo.appendingPathComponent(".gitignore"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "config"], in: repo)
        try FileManager.default.createSymbolicLink(
            at: config.appendingPathComponent("out.link"), withDestinationURL: bystander)
        try GitFixture.run(["worktree", "add", "-b", "side", worktree.path], in: repo)

        let report = WorktreeCarry.copy(["config"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, [])
        XCTAssertEqual(
            report.skipped, [CarryReport.Skipped(name: "config", reason: .leavesTheWorkspace)])
    }

    func test_ignoredEntries_keepsTheFoldedFilesReachableBehindTheFolder() throws {
        let log = repo.appendingPathComponent("log", isDirectory: true)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        try GitFixture.write("", to: log.appendingPathComponent(".keep"))
        try GitFixture.write("log/*.log\n.env\n", to: repo.appendingPathComponent(".gitignore"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "log"], in: repo)
        try GitFixture.write("a\n", to: log.appendingPathComponent("one.log"))
        try GitFixture.write("b\n", to: log.appendingPathComponent("two.log"))
        try GitFixture.write("S=1\n", to: repo.appendingPathComponent(".env"))

        let catalog = try XCTUnwrap(WorktreeCarry.ignoredEntries(in: repo, chosen: []))

        XCTAssertEqual(catalog.resting, [".env", "log"], "at rest the folder stands in for its files")
        XCTAssertEqual(
            catalog.entries, [".env", "log", "log/one.log", "log/two.log"],
            "every file is still a row, sitting under the folder it folded into")
        XCTAssertEqual(catalog.fileCounts, ["log": 2], "so the row can say what it stands for")
    }

    func test_ignoredEntries_doesNotFoldAFolderHoldingSomethingAlreadyChosen() throws {
        let credentials = repo.appendingPathComponent("config/credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        try GitFixture.write("x\n", to: credentials.appendingPathComponent(".keep"))
        try GitFixture.write("config/credentials/*.key\n", to: repo.appendingPathComponent(".gitignore"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "creds"], in: repo)
        try GitFixture.write("p\n", to: credentials.appendingPathComponent("production.key"))
        try GitFixture.write("d\n", to: credentials.appendingPathComponent("development.key"))

        XCTAssertEqual(
            WorktreeCarry.ignoredEntries(in: repo, chosen: [])?.resting, ["config/credentials"],
            "with nothing chosen there it folds")

        XCTAssertEqual(
            WorktreeCarry.ignoredEntries(
                in: repo, chosen: ["config/credentials/production.key"])?.resting,
            ["config/credentials/development.key", "config/credentials/production.key"],
            "a chosen child expands it, so the pick sits among its siblings")
    }

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
            WorktreeCarry.ignoredEntries(in: repo, chosen: [])?.resting,
            ["pkg/.turbo", "pkg/node_modules"])
    }

    func test_ignoredEntries_doesNotFoldASingleFile() throws {
        let config = repo.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try GitFixture.write("x\n", to: config.appendingPathComponent("app.yml"))
        try GitFixture.write("config/*.key\n", to: repo.appendingPathComponent(".gitignore"))
        try GitFixture.run(["add", "."], in: repo)
        try GitFixture.run(["commit", "-m", "config"], in: repo)
        try GitFixture.write("k\n", to: config.appendingPathComponent("master.key"))

        XCTAssertEqual(
            WorktreeCarry.ignoredEntries(in: repo, chosen: [])?.resting, ["config/master.key"])
    }

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
            WorktreeCarry.ignoredEntries(in: repo, chosen: [])?.resting,
            ["config/credentials/development.key"])
    }

    func test_ignoredEntries_leavesOutWhatGitTracks() throws {
        try GitFixture.write("SECRET=1\n", to: repo.appendingPathComponent(".env"))

        XCTAssertEqual(WorktreeCarry.ignoredEntries(in: repo, chosen: [])?.resting, [".env"])
    }

    func test_ignoredEntries_isNilWhenTheFolderIsNotARepo() {
        XCTAssertNil(WorktreeCarry.ignoredEntries(in: root, chosen: []))
    }

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

    func test_copy_reportsAnEntryThatIsNotThere() {
        let report = WorktreeCarry.copy(["node_modules"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, [])
        XCTAssertEqual(
            report.skipped, [CarryReport.Skipped(name: "node_modules", reason: .notThere)])
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: worktree.path), [])
    }

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

    func test_copy_doesNotTreatAGlobAsAMatchOnTrackedFiles() throws {
        try GitFixture.write("ignored\n", to: repo.appendingPathComponent("*.txt"))

        let report = WorktreeCarry.copy(["*.txt"], from: repo, into: worktree)

        XCTAssertEqual(report.carried, ["*.txt"])
        XCTAssertEqual(report.skipped, [])
    }

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
