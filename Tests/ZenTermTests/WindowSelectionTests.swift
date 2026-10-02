import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class WindowSelectionTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.map { AttentionCenter.shared.forget(windowID: $0.windowID) }
        controller = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
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
            .newTab, .splitVertical, .closePane, .closeTab, .renameTab, .closeWorkspace, .newWorkspace,
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
}
