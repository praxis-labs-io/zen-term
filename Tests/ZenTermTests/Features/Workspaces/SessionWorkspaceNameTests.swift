import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class SessionWorkspaceNameTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private let jobs = ProgramJobs()

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [unowned self] in
            let surface = RecordingSurface()
            spawned.append(surface)
            return surface
        }
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        jobs.stopAll()
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.map { AttentionCenter.shared.forget(windowID: $0.windowID) }
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    private var home: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

    private func makeWindow() -> WindowController {
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: home)
        c.mountAndStart()
        controller = c
        return c
    }

    private func sidebarTitles(_ c: WindowController) -> [String] {
        c.sidebarForTesting.view.rowsForTesting.map(\.titleForTesting)
    }

    private func changeFolder(of surface: RecordingSurface, to path: String) {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        surface.currentDirectory = folder
        surface.delegate?.surface(surface, cwdDidChange: folder)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func openRowNames(in c: WindowController) -> [String] {
        descendants(of: c.window.contentView!).compactMap { $0 as? RepoPickerOverlay }.first?.rowViews
            .compactMap { ($0 as? RepoPickerOverlay.RowView)?.running?.name } ?? []
    }

    func test_anOpenPicker_rereadsTheSessionsName_whenItsFolderChanges() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        c.handle(.toggleRepoPicker)
        waitUntil(!openRowNames(in: c).isEmpty, "the picker to list the open workspace")
        XCTAssertEqual(openRowNames(in: c), [PathDisplay.homeName])

        changeFolder(of: pane, to: "/tmp/zen-term")

        XCTAssertEqual(openRowNames(in: c), ["zen-term"])
    }

    func test_aSessionAtHome_readsAsTheHomeFolder_neverATildeOrANumber() {
        let c = makeWindow()

        XCTAssertEqual(sidebarTitles(c), [PathDisplay.homeName])
        XCTAssertEqual(c.window.title, PathDisplay.homeName)
    }

    func test_aFolderChangeInTheActiveTab_renamesTheSession_inTheSidebarAndTheWindow() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)

        changeFolder(of: pane, to: "/tmp/zen-term")

        XCTAssertEqual(sidebarTitles(c), ["zen-term"])
        XCTAssertEqual(c.window.title, "zen-term")
    }

    func test_switchingTheActiveTab_renamesTheSessionForThatTabsFolder() throws {
        let c = makeWindow()
        c.newTabForTesting()
        let second = try XCTUnwrap(spawned.last)
        changeFolder(of: second, to: "/tmp/api")
        XCTAssertEqual(sidebarTitles(c), ["api"])

        c.selectTabForTesting(index: 0)

        XCTAssertEqual(sidebarTitles(c), [PathDisplay.homeName])
    }

    func test_aRunningJob_doesNotRenameTheSession() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)

        pane.foregroundProcessGroupID = try jobs.start(named: "nvim")
        c.pollTitlesForTesting()

        XCTAssertEqual(c.tabTitlesForTesting.first, "nvim", "precondition: the tab follows the job")
        XCTAssertEqual(sidebarTitles(c), [PathDisplay.homeName])
    }

    func test_aRenamedSession_keepsItsName_throughAFolderChange() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)
        c.renameWorkspace(c.activeWorkspaceIDForTesting, to: "scratch")

        changeFolder(of: pane, to: "/tmp/api")
        c.pollTitlesForTesting()

        XCTAssertEqual(sidebarTitles(c), ["scratch"])
    }

    func test_twoSessionsInOneFolder_shareItsName() {
        let c = makeWindow()

        _ = c.openUnconfiguredWorkspace(at: home)

        XCTAssertEqual(c.workspaceNamesForTesting, [PathDisplay.homeName, PathDisplay.homeName])
    }

    func test_aSessionAtTheRoot_readsAsTheRoot_neverTheHomeFolder() throws {
        let c = makeWindow()
        let pane = try XCTUnwrap(spawned.first)

        changeFolder(of: pane, to: "/")

        XCTAssertEqual(sidebarTitles(c), ["/"])
    }

    func test_switchingTheActiveTab_tellsOtherWindowsAtOnce() throws {
        let c = makeWindow()
        c.newTabForTesting()
        changeFolder(of: try XCTUnwrap(spawned.last), to: "/tmp/api")
        var notified = 0
        c.onOpenWorkspacesChanged = { notified += 1 }

        c.selectTabForTesting(index: 0)

        XCTAssertEqual(notified, 1, "other windows' lists re-read the session's name without waiting for the poll")
        XCTAssertEqual(c.workspaceNamesForTesting, [PathDisplay.homeName])
    }

    func test_closingTheActiveTab_tellsOtherWindowsAtOnce() throws {
        let c = makeWindow()
        c.newTabForTesting()
        changeFolder(of: try XCTUnwrap(spawned.last), to: "/tmp/api")
        var notified = 0
        c.onOpenWorkspacesChanged = { notified += 1 }

        c.closeTabForTesting(index: 1)

        XCTAssertEqual(notified, 1, "other windows' lists re-read the session's name without waiting for the poll")
        XCTAssertEqual(c.workspaceNamesForTesting, [PathDisplay.homeName])
    }
}
