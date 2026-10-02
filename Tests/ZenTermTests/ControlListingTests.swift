import AppKit
import ControlProtocol
import TerminalKit
import XCTest

@testable import ZenTerm

final class ControlListingTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private let originalPresence = WindowController.isPresent
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        WindowController.isPresent = { _ in true }
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
            .appendingPathComponent("zenterm-listing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.map { AttentionCenter.shared.forget(windowID: $0.windowID) }
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        c.mountAndStart()
        controller = c
        return c
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func token(of surface: RecordingSurface) throws -> Int {
        try XCTUnwrap(surface.lastConfig?.environment["ZEN_PANE"].flatMap(Int.init))
    }

    private func list(_ c: WindowController) throws -> ListResult {
        let reply = ControlResponder { [c] }.respond(to: ControlRequest(id: 1, cmd: .list))
        return try XCTUnwrap(try reply.get() as? ListResult)
    }

    private func openWorktree(in c: WindowController) {
        let parent = Workspace(title: "alpha", path: FileManager.default.temporaryDirectory, tabs: [], env: [:])
        let worktree = Worktree(path: root, branch: "one", head: "0000000", isLocked: false)
        c.openWorkspaceForTesting(
            Workspace(title: "alpha: one", path: root, tabs: [], env: [:]),
            origin: WorktreeOrigin(parent: parent, worktree: worktree))
    }

    func test_listsABackgroundWorkspaceAndAnOpenDrawer() throws {
        let c = makeWindow()
        let backgroundPane = try XCTUnwrap(spawned.first)
        backgroundPane.title = "vim notes.md"
        backgroundPane.currentDirectory = URL(fileURLWithPath: "/tmp/notes")
        backgroundPane.isBusy = true
        backgroundPane.delegate?.surface(
            backgroundPane,
            didPostNotification: TerminalNotification(title: "Claude Code", body: "Claude needs your permission"))
        drainMainQueue()

        openWorktree(in: c)
        let worktreePane = try XCTUnwrap(spawned.last)
        c.handle(.toggleBottomDrawer)
        let drawer = try XCTUnwrap(spawned.last)
        XCTAssertFalse(drawer === worktreePane, "opening the drawer spawns its own surface")

        let window = try XCTUnwrap(try list(c).windows.first)
        XCTAssertEqual(window.id, "w\(c.windowID)")
        XCTAssertEqual(window.workspaces.map(\.title), [c.workspaceNamesForTesting[0], "alpha: one"])

        let background = window.workspaces[0]
        XCTAssertFalse(background.active)
        XCTAssertFalse(background.configured)
        XCTAssertNil(background.worktree)
        let backgroundTab = try XCTUnwrap(background.tabs.first)
        XCTAssertEqual(backgroundTab.id, "w\(c.windowID).t1")
        XCTAssertTrue(backgroundTab.active, "the active tab of a workspace in the background")
        XCTAssertEqual(
            backgroundTab.panes,
            [
                ListResult.Pane(
                    token: try token(of: backgroundPane), drawer: nil, title: "vim notes.md", cwd: "/tmp/notes",
                    busy: true, agent: ListResult.Agent(name: "Claude Code", state: .waiting))
            ])

        let active = window.workspaces[1]
        XCTAssertTrue(active.active)
        XCTAssertEqual(active.folder, root.path)
        XCTAssertEqual(
            active.worktree, ListResult.Worktree(name: "one", parent: FileManager.default.temporaryDirectory.path))
        let activeTab = try XCTUnwrap(active.tabs.first)
        XCTAssertEqual(activeTab.panes.map(\.token), [try token(of: worktreePane), try token(of: drawer)])
        XCTAssertEqual(activeTab.panes.map(\.drawer), [nil, .bottom])
        XCTAssertEqual(activeTab.panes.map(\.agent), [nil, nil])
    }

    func test_everyPaneAndDrawerShellIsToldTheControlSocket() throws {
        let c = makeWindow()
        c.handle(.toggleBottomDrawer)
        XCTAssertEqual(spawned.count, 2)
        for surface in spawned {
            XCTAssertEqual(surface.lastConfig?.environment["ZEN_CONTROL_SOCK"], ControlServer.socketPath)
            XCTAssertEqual(surface.lastConfig?.environment["ZEN_SOCK"], NavSocketServer.socketPath)
        }
    }

    func test_locatesADrawerByItsToken() throws {
        let c = makeWindow()
        c.handle(.toggleBottomDrawer)
        let drawer = try XCTUnwrap(spawned.last)
        let responder = ControlResponder { [c] }

        let found = try XCTUnwrap(responder.locate(pane: try token(of: drawer)))

        XCTAssertTrue(found.window === c)
        XCTAssertEqual(found.tab, c.activeTabIDForTesting)
        XCTAssertEqual(found.pane.drawer, .bottom)
        XCTAssertTrue(found.pane.surface === drawer)
        XCTAssertNil(responder.locate(pane: Int.max))
    }

    func test_helloNamesTheProtocolVersion() throws {
        let reply = ControlResponder { [] }.respond(to: ControlRequest(id: 1, cmd: .hello))
        let hello = try XCTUnwrap(try reply.get() as? HelloResult)
        XCTAssertEqual(hello.protocolVersion, ControlWire.version)
        XCTAssertEqual(hello.app, AppVersion.current)
    }
}
