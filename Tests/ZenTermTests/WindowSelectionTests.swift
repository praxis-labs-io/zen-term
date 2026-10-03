import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class WindowSelectionTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private let originalPresence = WindowController.isPresent
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private var tempRoot: URL!

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
        SidebarController.resetLastChoiceForTesting()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.map { AttentionCenter.shared.forget(windowID: $0.windowID) }
        controller = nil
        spawned = []
        ConfigLoader.defaultRootOverrideForTesting = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        SidebarController.resetLastChoiceForTesting()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func makeHostWindow() -> (WindowController, WorkspaceID) {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            initialCWD: FileManager.default.temporaryDirectory)
        c.mountAndStart()
        controller = c
        let workspace = c.activeWorkspaceIDForTesting
        c.selectHostForTesting(SSHHostID(name: "devbox"))
        return (c, workspace)
    }

    func test_aHost_ignoresChordsThatNeedATab() {
        let (c, workspace) = makeHostWindow()

        for chord: KeyInterceptor.ReservedChord in [
            .splitVertical, .closeTab, .renameTab, .closeWorkspace, .newWorkspace,
            .selectTab(1),
        ] {
            c.handle(chord)
        }

        XCTAssertEqual(c.workspaceIDsForTesting, [workspace])
        XCTAssertEqual(c.tabIDsForTesting(workspace: workspace).count, 1)
        XCTAssertNil(c.activeTabIDForTesting)
        XCTAssertFalse(c.isModalOverlayOpen)
        XCTAssertFalse(c.isConfirmOpen)
    }

    func test_aHost_rendersNoTabs() {
        let (c, _) = makeHostWindow()

        XCTAssertEqual(c.tabOrderForTesting, [])
    }

    func test_aHost_opensAndClosesTheCommandPalette() {
        let (c, _) = makeHostWindow()

        c.handle(.toggleCommandPalette)
        XCTAssertTrue(c.isModalOverlayOpen)

        c.handle(.toggleCommandPalette)
        XCTAssertFalse(c.isModalOverlayOpen)
    }

    func test_aHost_opensSettings() {
        let (c, _) = makeHostWindow()

        c.handle(.openSettings)

        XCTAssertTrue(c.isModalOverlayOpen)
    }

    func test_aHost_opensTheWorkspacePicker() {
        let (c, _) = makeHostWindow()

        c.handle(.toggleRepoPicker)

        waitUntil(c.isRepoPickerOpen, "the picker to open")
    }

    func test_aHost_switchesToAWorkspaceByNumber() {
        let (c, workspace) = makeHostWindow()

        c.handle(.selectWorkspace(1))

        XCTAssertEqual(c.activeTabIDForTesting, c.tabIDsForTesting(workspace: workspace).first)
        XCTAssertEqual(c.tabOrderForTesting, c.tabIDsForTesting(workspace: workspace))
    }

    func test_aHost_closesTheWindow() {
        let (c, _) = makeHostWindow()
        var closed = false
        c.onClosed = { closed = true }

        c.handle(.closeWindow)

        XCTAssertTrue(closed)
    }

    private func makeFocusedWorkspaceWindow() throws -> (WindowController, RecordingSurface) {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            initialCWD: FileManager.default.temporaryDirectory)
        controller = c
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        let surface = try XCTUnwrap(spawned.last)
        surface.focus()
        XCTAssertTrue(c.window.firstResponder === surface.view, "precondition: the workspace's pane holds focus")
        return (c, surface)
    }

    func test_aHost_takesTheWorkspacesCanvasOffTheWindow() throws {
        let (c, surface) = try makeFocusedWorkspaceWindow()

        c.selectHostForTesting(SSHHostID(name: "devbox"))

        XCTAssertNil(surface.view.window, "the workspace's pane is no longer mounted under a host")
    }

    func test_aHost_movesFocusFromTheWorkspacesPaneToConnect() throws {
        let (c, _) = try makeFocusedWorkspaceWindow()

        c.selectHostForTesting(SSHHostID(name: "devbox"))

        XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting)
        XCTAssertFalse(spawned.contains { $0.view === c.window.firstResponder })
    }

    func test_aHost_titlesTheWindowWithItsName() throws {
        let (c, _) = try makeFocusedWorkspaceWindow()

        c.selectHostForTesting(SSHHostID(name: "devbox"))

        XCTAssertEqual(c.window.title, "devbox")
    }

    func test_selectingTheWorkspaceAgain_remountsAndFocusesItsPane() throws {
        let (c, surface) = try makeFocusedWorkspaceWindow()
        let name = try XCTUnwrap(c.workspaceNamesForTesting.first)
        c.selectHostForTesting(SSHHostID(name: "devbox"))

        c.handle(.selectWorkspace(1))

        XCTAssertTrue(surface.view.window === c.window)
        XCTAssertTrue(c.window.firstResponder === surface.view)
        XCTAssertEqual(c.window.title, name)
    }

    private func toastViews(_ c: WindowController) -> [ToastView] {
        guard let content = c.window.contentView else { return [] }
        return descendants(of: content).compactMap { $0 as? ToastView }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    func test_aHost_togglesTheSidebar() throws {
        let (c, _) = try makeFocusedWorkspaceWindow()
        c.selectHostForTesting(SSHHostID(name: "devbox"))
        XCTAssertTrue(c.sidebarForTesting.isDocked, "precondition: the sidebar is docked")

        c.handle(.toggleSidebar)

        XCTAssertFalse(c.sidebarForTesting.isDocked)
    }

    func test_aHost_movesFocusIntoTheSidebar() throws {
        let (c, _) = try makeFocusedWorkspaceWindow()
        c.selectHostForTesting(SSHHostID(name: "devbox"))

        c.handle(.focusSidebar)

        XCTAssertTrue(c.sidebarForTesting.hasFocus)
    }

    func test_aHost_hidingAFloatingSidebar_handsFocusToConnect() throws {
        let (c, _) = try makeFocusedWorkspaceWindow()
        c.window.setContentSize(c.window.contentMinSize)
        c.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        c.selectHostForTesting(SSHHostID(name: "devbox"))
        c.handle(.toggleSidebar)
        XCTAssertTrue(c.sidebarForTesting.isRevealed, "precondition: too narrow to dock, so the sidebar floats")
        XCTAssertTrue(c.sidebarForTesting.hasFocus, "precondition: the floating sidebar takes focus")

        c.handle(.toggleSidebar)

        XCTAssertFalse(c.sidebarForTesting.hasFocus)
        XCTAssertTrue(c.window.firstResponder === c.connectViewForTesting)
    }

    func test_aHost_dismissesTheOldestToast() throws {
        let (c, _) = try makeFocusedWorkspaceWindow()
        c.selectHostForTesting(SSHHostID(name: "devbox"))
        c.showToast(ToastContent(variant: .info, title: "First", message: "One."))
        XCTAssertEqual(toastViews(c).count, 1, "precondition: a toast is up")

        c.handle(.dismissToast)
        drainMainQueue()

        XCTAssertTrue(toastViews(c).isEmpty)
    }

    func test_aHost_dismissesEveryToast() throws {
        let (c, _) = try makeFocusedWorkspaceWindow()
        c.selectHostForTesting(SSHHostID(name: "devbox"))
        c.showToast(ToastContent(variant: .info, title: "First", message: "One."))
        c.showToast(ToastContent(variant: .info, title: "Second", message: "Two."))
        XCTAssertEqual(toastViews(c).count, 2, "precondition: two toasts are up")

        c.handle(.dismissAllToasts)
        drainMainQueue()

        XCTAssertTrue(toastViews(c).isEmpty)
    }

    func test_aHost_jumpsToAnAgentWaitingInAWorkspace() throws {
        var config = GeneralConfig.builtIn
        config.ai = "pi"
        GeneralConfig.setCurrentForTesting(config)
        WindowController.isPresent = { _ in false }
        let (c, surface) = try makeFocusedWorkspaceWindow()
        let workspace = c.activeWorkspaceIDForTesting
        let agent = try XCTUnwrap(c.focusedSurfaceIDForTesting)
        surface.delegate?.surface(
            surface, didPostNotification: TerminalNotification(title: "pi", body: "Wants to run swift test"))
        drainMainQueue()
        XCTAssertEqual(c.agentStateForTesting(agent), .waiting, "precondition: the agent is waiting")
        c.selectHostForTesting(SSHHostID(name: "devbox"))

        c.handle(.nextWaitingAgent)

        XCTAssertEqual(c.tabOrderForTesting, c.tabIDsForTesting(workspace: workspace))
        XCTAssertEqual(c.focusedSurfaceIDForTesting, agent)
        XCTAssertTrue(c.window.firstResponder === surface.view)
    }
}
