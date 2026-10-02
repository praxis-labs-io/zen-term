import AppKit
import ControlProtocol
import TerminalKit
import XCTest

@testable import ZenTerm

final class ControlWorktreeTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var spawned: [RecordingSurface] = []
    private var configured: [Workspace] = []
    private let removals = WorktreeRemovalTracker()
    private var root: URL!
    private var repo: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        GeneralConfig.setCurrentForTesting(.builtIn)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zt-control-worktree-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        WorktreeStore.rootOverrideForTesting = root.appendingPathComponent("worktrees", isDirectory: true)
        repo = try GitFixture.makeRepo(at: root.appendingPathComponent("repo", isDirectory: true))
        try GitFixture.write("SECRET=1\n", to: repo.appendingPathComponent(".env"))
        configured = [entry]
        removals.onChanged = { [weak self] change in
            for c in self?.controllers ?? [] { c.worktreeRemovalsChanged(change) }
        }
    }

    override func tearDownWithError() throws {
        for c in controllers {
            c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: c.windowID)
        }
        controllers = []
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WorktreeStore.rootOverrideForTesting = nil
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var entry: Workspace { Workspace(title: "Repo", path: repo, tabs: [], env: [:], carry: [".env"]) }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.worktreeRemovals = removals
        c.mountAndStart()
        controllers.append(c)
        return c
    }

    private var responder: ControlResponder {
        var responder = ControlResponder(
            windows: { [unowned self] in controllers }, keyWindow: { [unowned self] in controllers.first })
        responder.loadWorkspaces = { [unowned self] completion in
            let entries = configured
            DispatchQueue.main.async { completion(entries) }
        }
        responder.worktreeRemovals = removals
        return responder
    }

    private func send(_ cmd: ControlCommand, _ args: ControlArgs = ControlArgs(), from pane: Int? = nil) throws
        -> ControlReply
    {
        var reply: ControlReply?
        responder.respond(
            to: ControlRequest(id: 1, cmd: cmd, args: args, caller: pane.map(ControlCaller.init(pane:)))
        ) { reply = $0 }
        waitUntil(reply != nil, "\(cmd.rawValue) to answer", timeout: 15)
        return try XCTUnwrap(reply)
    }

    private func result<P>(_ reply: ControlReply, as: P.Type) throws -> P {
        try XCTUnwrap(try reply.get() as? P, "\(reply)")
    }

    private struct AnsweredOK: Error {}

    private func error(_ reply: ControlReply) throws -> ControlError {
        guard case .failure(let error) = reply else {
            XCTFail("expected an error, got \(reply)")
            throw AnsweredOK()
        }
        return error
    }

    private func repoPane(in c: WindowController) throws -> Int {
        c.openWorkspaceForTesting(entry)
        return try XCTUnwrap(spawned.last?.lastConfig?.environment["ZEN_PANE"].flatMap(Int.init))
    }

    private func names(in c: WindowController) -> [String] { c.listing().workspaces.map(\.title) }

    private func openWorktree(_ branch: String, in c: WindowController) throws -> Worktree {
        let worktree = try WorktreeStore.create(branch: branch, in: repo)
        let opened = RepoPickerOverlay.workspace(for: worktree, parent: entry, repoRoot: repo)
        c.openWorkspaceForTesting(opened, origin: WorktreeOrigin(parent: entry, worktree: worktree))
        return worktree
    }

    func test_createFromAConfiguredPane_opensTheWorktreeUnderItsParentWithItsCarry_andLeavesTheView() throws {
        let c = makeWindow()
        let caller = try repoPane(in: c)
        c.openWorkspaceForTesting(Workspace(title: "Other", path: root, tabs: [], env: [:]))
        let showing = c.activeWorkspaceIDForTesting

        let made = try result(
            send(.worktreeCreate, ControlArgs(branch: "feat/x"), from: caller), as: WorktreeResult.self)

        XCTAssertEqual(names(in: c), ["Workspace 1", "Repo", "Repo: feat/x", "Other"])
        XCTAssertEqual(c.activeWorkspaceIDForTesting, showing)
        XCTAssertEqual(made.workspace.title, "Repo: feat/x")
        XCTAssertEqual(made.workspace.worktree, ListResult.Worktree(name: "feat/x", parent: repo.path))
        XCTAssertEqual(made.window, ControlAddress.window(c.windowID))
        XCTAssertEqual(made.carry, WorktreeResult.Carry(carried: [".env"], skipped: []))
        XCTAssertTrue(GitFixture.exists(URL(fileURLWithPath: made.path).appendingPathComponent(".env")))
        XCTAssertEqual(try WorktreeStore.list(in: repo).map(\.path.path), [made.path])
    }

    func test_createWithFocusSwitchesToTheWorktree() throws {
        let c = makeWindow()
        let caller = try repoPane(in: c)

        _ = try result(
            send(.worktreeCreate, ControlArgs(focus: true, branch: "feat/x"), from: caller), as: WorktreeResult.self)

        XCTAssertEqual(c.activeWorkspaceIDForTesting, c.workspaceIDsForTesting.last)
        XCTAssertEqual(c.workspaceNamesForTesting.last, "Repo: feat/x")
    }

    func test_createFromAWorktreesPaneMakesASiblingFromItsParentsEntry() throws {
        let c = makeWindow()
        _ = try openWorktree("feat/a", in: c)
        let caller = try XCTUnwrap(spawned.last?.lastConfig?.environment["ZEN_PANE"].flatMap(Int.init))

        let made = try result(
            send(.worktreeCreate, ControlArgs(branch: "feat/b"), from: caller), as: WorktreeResult.self)

        XCTAssertEqual(made.workspace.worktree?.parent, repo.path)
    }

    func test_anInvalidBranchFailsWithTheStoresMessage_andCreatesNothing() throws {
        let c = makeWindow()
        let caller = try repoPane(in: c)
        let before = names(in: c)

        let failure = try error(send(.worktreeCreate, ControlArgs(branch: "feat..x"), from: caller))

        XCTAssertEqual(failure.code, .failed)
        XCTAssertEqual(failure.message, "feat..x is not a branch name git will take.")
        XCTAssertEqual(try GitFixture.branches(in: repo), ["main"])
        XCTAssertEqual(names(in: c), before)
    }

    func test_aWorkspaceWithNoEntryIsRefused_andTheEntryIsReadFresh() throws {
        let c = makeWindow()
        let caller = try repoPane(in: c)
        configured = []

        let refused = try error(send(.worktreeCreate, ControlArgs(branch: "feat/x"), from: caller))

        XCTAssertEqual(refused.code, .refused)
        XCTAssertNil(refused.details)
        XCTAssertTrue(try WorktreeStore.list(in: repo).isEmpty)
    }

    func test_aConfiguredTitleThatIsNotOpenStillResolves() throws {
        _ = makeWindow()

        let listed = try result(send(.worktreeList, ControlArgs(workspace: "Repo")), as: WorktreeListResult.self)

        XCTAssertEqual(listed.worktrees, [])
    }

    func test_listReturnsTheReposWorktrees() throws {
        let c = makeWindow()
        let caller = try repoPane(in: c)
        let worktree = try WorktreeStore.create(branch: "feat/x", in: repo)

        let listed = try result(send(.worktreeList, from: caller), as: WorktreeListResult.self)

        XCTAssertEqual(
            listed.worktrees,
            [.init(path: worktree.path.path, branch: "feat/x", head: worktree.head, locked: false)])
    }

    func test_removeRefusesADirtyWorktreeAndListsItsFiles_thenForceRemovesItAndClosesItsTabs() throws {
        let c = makeWindow()
        let worktree = try openWorktree("feat/x", in: c)
        try GitFixture.write("draft\n", to: worktree.path.appendingPathComponent("notes.txt"))

        let refused = try error(send(.worktreeRemove, ControlArgs(workspace: repo.path, branch: "feat/x")))

        XCTAssertEqual(refused.code, .refused)
        XCTAssertEqual(refused.message, "Removing feat/x would lose 1 uncommitted file.")
        XCTAssertEqual(refused.details?.files, ["notes.txt"])
        XCTAssertEqual(refused.details?.lostCommits, 0)
        XCTAssertTrue(GitFixture.exists(worktree.path))
        XCTAssertTrue(names(in: c).contains("Repo: feat/x"))

        _ = try result(
            send(.worktreeRemove, ControlArgs(workspace: repo.path, force: true, branch: "feat/x")),
            as: NoPayload.self)

        XCTAssertFalse(GitFixture.exists(worktree.path))
        XCTAssertFalse(names(in: c).contains("Repo: feat/x"))
        XCTAssertFalse(removals.isRemoving(worktree.path))
    }

    func test_removeRefusesACleanWorktreeWhoseTabIsRunning_andNamesWhatWouldStop_untilForced() throws {
        let c = makeWindow()
        let worktree = try openWorktree("feat/x", in: c)
        let busy = try XCTUnwrap(spawned.last)
        busy.isBusy = true
        busy.title = "npm run dev"

        let refused = try error(send(.worktreeRemove, ControlArgs(workspace: repo.path, branch: "feat/x")))

        XCTAssertEqual(refused.code, .refused)
        XCTAssertEqual(refused.message, "Removing feat/x would stop npm run dev.")
        XCTAssertEqual(refused.details?.panes.map(\.title), ["npm run dev"])
        XCTAssertEqual(refused.details?.files, [])
        XCTAssertTrue(GitFixture.exists(worktree.path))

        _ = try result(
            send(.worktreeRemove, ControlArgs(workspace: repo.path, force: true, branch: "feat/x")),
            as: NoPayload.self)

        XCTAssertFalse(GitFixture.exists(worktree.path))
        XCTAssertFalse(names(in: c).contains("Repo: feat/x"))
    }

    func test_removeRefusesACleanIdleWorktreeThatIsAllItsWindowHolds_untilForced() throws {
        let c = makeWindow()
        let home = try XCTUnwrap(c.workspaceIDsForTesting.first)
        let worktree = try openWorktree("feat/x", in: c)
        for tab in c.tabIDsForTesting(workspace: home) { c.closeTabForTesting(tab: tab) }
        XCTAssertEqual(c.workspaceNamesForTesting, ["Repo: feat/x"])

        let refused = try error(send(.worktreeRemove, ControlArgs(workspace: repo.path, branch: "feat/x")))

        XCTAssertEqual(refused.code, .refused)
        XCTAssertEqual(refused.message, "Removing feat/x would close the window.")
        XCTAssertEqual(refused.details?.closesWindow, true)
        XCTAssertTrue(GitFixture.exists(worktree.path))

        _ = try result(
            send(.worktreeRemove, ControlArgs(workspace: repo.path, force: true, branch: "feat/x")),
            as: NoPayload.self)

        XCTAssertFalse(GitFixture.exists(worktree.path))
    }

    func test_removeByPathTakesACleanWorktreeWithoutForce() throws {
        let c = makeWindow()
        let caller = try repoPane(in: c)
        let worktree = try WorktreeStore.create(branch: "feat/x", in: repo)

        _ = try result(send(.worktreeRemove, ControlArgs(path: worktree.path.path), from: caller), as: NoPayload.self)

        XCTAssertFalse(GitFixture.exists(worktree.path))
    }

    func test_removeRefusesALockedWorktreeEvenWithForce() throws {
        let c = makeWindow()
        let caller = try repoPane(in: c)
        let worktree = try WorktreeStore.create(branch: "feat/x", in: repo)
        try GitFixture.run(["worktree", "lock", worktree.path.path], in: repo)

        let refused = try error(
            send(.worktreeRemove, ControlArgs(force: true, branch: "feat/x"), from: caller))

        XCTAssertEqual(refused.code, .refused)
        XCTAssertEqual(refused.message, "feat-x is locked. Unlock it before removing it.")
        XCTAssertTrue(GitFixture.exists(worktree.path))
    }

    func test_removeOfABranchWithNoWorktreeIsNotFound() throws {
        let c = makeWindow()
        let caller = try repoPane(in: c)

        let missing = try error(send(.worktreeRemove, ControlArgs(branch: "feat/none"), from: caller))

        XCTAssertEqual(missing.code, .notFound)
    }
}
