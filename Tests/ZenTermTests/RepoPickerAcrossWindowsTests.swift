import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class RepoPickerAcrossWindowsTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var first: WindowController?
    private var second: WindowController?
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        GeneralConfig.setCurrentForTesting(.builtIn)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-across-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        first?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        second?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        first = nil
        second = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private let twoWorkspaces = """
        [Alpha]
        path = ~/Dev/alpha

        [Beta]
        path = ~/Dev/beta
        """

    private func seedWorkspaces(_ text: String) throws {
        try text.write(to: tempRoot.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
    }

    // Wired the way `AppDelegate.newWindow` wires them, minus the ordering a test must not do.
    private func makeWindows() -> (WindowController, WindowController) {
        func make() -> WindowController {
            let c = WindowController(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                initialCWD: FileManager.default.temporaryDirectory)
            c.mountAndStart()
            return c
        }
        let one = make()
        let two = make()
        first = one
        second = two
        for window in [one, two] {
            let others = { [weak one, weak two] in [one, two].compactMap { $0 } }
            window.isWorkspaceOpenInAnotherWindow = { [weak window] path in
                AppDelegate.window(holding: path, among: others(), asking: window) != nil
            }
            window.revealWorkspaceInAnotherWindow = { [weak window] path in
                guard let other = AppDelegate.window(holding: path, among: others(), asking: window)
                else { return false }
                other.activateWorkspace(at: path)
                return true
            }
        }
        return (one, two)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func pickers(in c: WindowController) -> [RepoPickerOverlay] {
        descendants(of: c.window.contentView!).compactMap { $0 as? RepoPickerOverlay }
    }

    private func openPicker(in c: WindowController) throws -> RepoPickerOverlay {
        c.handle(.toggleRepoPicker)
        waitUntil(!pickers(in: c).isEmpty, "the picker to be presented")
        return try XCTUnwrap(pickers(in: c).first)
    }

    private func pressReturn(in picker: RepoPickerOverlay) {
        guard
            let field = descendants(of: picker).compactMap({ $0 as? NSTextField })
                .first(where: { ($0.delegate as? PaletteOverlay) === picker })
        else { return XCTFail("the picker has no search field to press Return in") }
        _ = picker.control(
            field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    private func markers(in picker: RepoPickerOverlay) -> [String] {
        picker.rowViews.compactMap { $0 as? RepoPickerOverlay.RowView }.flatMap { row in
            descendants(of: row).compactMap { ($0 as? NSTextField)?.stringValue }
                .filter { $0 == "open" || $0 == "open in another window" }
        }
    }

    private func hintIsShown(_ label: String, in picker: RepoPickerOverlay) -> Bool {
        guard
            let field = descendants(of: picker).compactMap({ $0 as? NSTextField })
                .first(where: { $0.stringValue == label })
        else { return false }
        return !field.isHiddenOrHasHiddenAncestor
    }

    func test_returnOnAWorkspaceOpenInAnotherWindow_switchesThere_ratherThanOpeningASecondCopy() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, two) = makeWindows()
        pressReturn(in: try openPicker(in: two))
        let alpha = two.activeWorkspaceIDForTesting
        let alphaTab = try XCTUnwrap(two.tabIDsForTesting(workspace: alpha).first)
        let alphaSurface = try XCTUnwrap(two.controllerForTesting(tab: alphaTab)?.allSurfaces.first)
        two.handle(.selectWorkspace(1))
        XCTAssertNotEqual(two.activeWorkspaceIDForTesting, alpha)

        pressReturn(in: try openPicker(in: one))

        XCTAssertEqual(one.workspaceNamesForTesting, ["Workspace 1"], "no second copy in the asking window")
        XCTAssertEqual(two.workspaceNamesForTesting, ["Workspace 1", "Alpha"], "nor a second in the holder")
        XCTAssertEqual(two.activeWorkspaceIDForTesting, alpha, "the window holding it switches to it")
        XCTAssertTrue(
            two.controllerForTesting(tab: alphaTab)?.allSurfaces.first === alphaSurface,
            "the same shell, so the recipe never ran twice")
        XCTAssertTrue(pickers(in: one).isEmpty, "the picker closes")
    }

    func test_aWorkspaceOpenInAnotherWindow_isMarkedAsOpenThere() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, two) = makeWindows()
        pressReturn(in: try openPicker(in: two))

        XCTAssertEqual(markers(in: try openPicker(in: one)), ["open in another window"])
    }

    func test_aWorkspaceOpenInThisWindow_staysMarkedOpen() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, _) = makeWindows()
        pressReturn(in: try openPicker(in: one))

        XCTAssertEqual(markers(in: try openPicker(in: one)), ["open"])
    }

    func test_theFooterReadsSwitchOverAWorkspaceOpenInAnotherWindow() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, two) = makeWindows()
        pressReturn(in: try openPicker(in: two))

        let picker = try openPicker(in: one)

        XCTAssertTrue(hintIsShown("switch", in: picker), "↵ crosses to the window holding it")
        XCTAssertFalse(hintIsShown("open", in: picker), "it is not opened a second time")
    }

    func test_aWorkspaceOpenNowhere_stillOpensIntoTheAskingWindow() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, two) = makeWindows()

        pressReturn(in: try openPicker(in: one))

        XCTAssertEqual(one.workspaceNamesForTesting, ["Workspace 1", "Alpha"])
        XCTAssertEqual(two.workspaceNamesForTesting, ["Workspace 1"])
    }
}
