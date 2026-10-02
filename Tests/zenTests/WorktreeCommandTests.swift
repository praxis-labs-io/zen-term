import ArgumentParser
import ControlProtocol
import XCTest

@testable import zen

final class WorktreeCommandTests: XCTestCase {
    func test_createParsesItsBranchAndFlags() throws {
        let create = try XCTUnwrap(
            try Zen.parseAsRoot(["worktree", "create", "feat/x", "--base", "current", "--existing", "--focus"])
                as? WorktreeCommands.Create)
        XCTAssertEqual(create.branch, "feat/x")
        XCTAssertEqual(create.base, .current)
        XCTAssertTrue(create.existing)
        XCTAssertTrue(create.focus)

        let plain = try XCTUnwrap(try Zen.parseAsRoot(["worktree", "create", "feat/y"]) as? WorktreeCommands.Create)
        XCTAssertEqual(plain.base.rawValue, "default")
    }

    func test_aBaseThatIsNeitherDefaultNorCurrentIsAUsageError() {
        XCTAssertEqual(Zen.exitCode(running: ["worktree", "create", "feat/x", "--base", "main"]), 2)
    }

    func test_removeSendsABranchAsABranch_andAFolderAsAnAbsolutePath() throws {
        let byBranch = try XCTUnwrap(
            try Zen.parseAsRoot(["worktree", "remove", "feat/x", "--force"]) as? WorktreeCommands.Remove)
        XCTAssertEqual(byBranch.args(in: "/src"), ControlArgs(force: true, branch: "feat/x"))

        let byFolder = try XCTUnwrap(
            try Zen.parseAsRoot(["worktree", "remove", "../wt", "--workspace", "./app"]) as? WorktreeCommands.Remove)
        XCTAssertEqual(
            byFolder.args(in: "/src/zen"), ControlArgs(workspace: "/src/zen/app", path: "/src/wt", force: false))
    }

    func test_aRemovalRefusalListsTheFilesItWouldLose_thenWhatItWouldStop() {
        let refusal = ControlError(
            .refused, "Removing feat/x would stop npm run dev and lose 2 uncommitted files.",
            details: .init(
                panes: [.init(token: 31, drawer: nil, title: "npm run dev", cwd: "/wt", busy: true, agent: nil)],
                floats: [], closesWindow: false, files: ["notes.txt", "src/a.swift"], lostCommits: 0))

        XCTAssertEqual(
            ControlClient.describe(refusal),
            """
            Removing feat/x would stop npm run dev and lose 2 uncommitted files. (refused)
              notes.txt
              src/a.swift
              31  npm run dev  /wt
            Pass --force to go ahead.
            """)
    }
}
