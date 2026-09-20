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
            window.openWorkspacesElsewhere = { [weak window] in
                others().filter { $0 !== window }.flatMap { $0.runningWorkspaces() }
            }
            window.revealWorkspaceElsewhere = { [weak window] id, workspace in
                guard
                    let other = others().first(where: { $0 !== window && $0.windowID == id }),
                    other.holdsWorkspace(workspace)
                else { return false }
                other.window.makeKeyAndOrderFront(nil)
                other.activateWorkspace(workspace)
                return true
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

    private func moveDown(in picker: RepoPickerOverlay) {
        guard
            let field = descendants(of: picker).compactMap({ $0 as? NSTextField })
                .first(where: { ($0.delegate as? PaletteOverlay) === picker })
        else { return XCTFail("the picker has no search field to arrow in") }
        _ = picker.control(
            field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
    }

    private func rowIndex(_ name: String, in picker: RepoPickerOverlay) -> Int? {
        picker.rowViews.firstIndex { view in
            guard let row = view as? RepoPickerOverlay.RowView else { return false }
            if let running = row.running { return running.id != nil && running.name == name }
            if let worktree = row.worktree { return (worktree.branch ?? worktree.head) == name }
            return row.label == name
        }
    }

    // Arrows onto the named row, so a test says which workspace it means rather than counting keystrokes.
    private func selectRow(_ name: String, in picker: RepoPickerOverlay) {
        guard let index = rowIndex(name, in: picker) else {
            return XCTFail("the picker has no row for \(name)")
        }
        for _ in 0..<picker.rowViews.count where picker.selected != index { moveDown(in: picker) }
        XCTAssertEqual(picker.selected, index, "the arrows never reached \(name)")
    }

    private func openPicker(in c: WindowController, on name: String) throws -> RepoPickerOverlay {
        let picker = try openPicker(in: c)
        selectRow(name, in: picker)
        return picker
    }

    // The section a row is listed under, which is what the "open" and "open elsewhere" markers used to say.
    private func section(at index: Int, in picker: RepoPickerOverlay) -> String? {
        picker.rowViews[..<index].reversed()
            .compactMap { ($0 as? PaletteSectionHeader)?.title }.first
    }

    private func section(of name: String, in picker: RepoPickerOverlay) -> String? {
        guard let index = rowIndex(name, in: picker) else { return nil }
        return section(at: index, in: picker)
    }

    private func pressReturn(in picker: RepoPickerOverlay) {
        guard
            let field = descendants(of: picker).compactMap({ $0 as? NSTextField })
                .first(where: { ($0.delegate as? PaletteOverlay) === picker })
        else { return XCTFail("the picker has no search field to press Return in") }
        _ = picker.control(
            field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
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
        pressReturn(in: try openPicker(in: two, on: "Alpha"))
        let alpha = two.activeWorkspaceIDForTesting
        let alphaTab = try XCTUnwrap(two.tabIDsForTesting(workspace: alpha).first)
        let alphaSurface = try XCTUnwrap(two.controllerForTesting(tab: alphaTab)?.allSurfaces.first)
        two.handle(.selectWorkspace(1))
        XCTAssertNotEqual(two.activeWorkspaceIDForTesting, alpha)

        pressReturn(in: try openPicker(in: one, on: "Alpha"))

        XCTAssertEqual(one.workspaceNamesForTesting, ["Workspace 1"], "no second copy in the asking window")
        XCTAssertEqual(two.workspaceNamesForTesting, ["Workspace 1", "Alpha"], "nor a second in the holder")
        XCTAssertEqual(two.activeWorkspaceIDForTesting, alpha, "the window holding it switches to it")
        XCTAssertTrue(
            two.controllerForTesting(tab: alphaTab)?.allSurfaces.first === alphaSurface,
            "the same shell, so the recipe never ran twice")
        XCTAssertTrue(pickers(in: one).isEmpty, "the picker closes")
    }

    func test_aWorkspaceOpenInAnotherWindow_isListedUnderOpenElsewhere() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, two) = makeWindows()
        pressReturn(in: try openPicker(in: two, on: "Alpha"))

        XCTAssertEqual(section(of: "Alpha", in: try openPicker(in: one)), "Open Elsewhere")
    }

    func test_aWorkspaceOpenInThisWindow_isListedUnderOpen() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, _) = makeWindows()
        pressReturn(in: try openPicker(in: one, on: "Alpha"))

        XCTAssertEqual(section(of: "Alpha", in: try openPicker(in: one)), "Open")
    }

    func test_aWorkspaceOpenNowhere_isListedUnderConfigured() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, _) = makeWindows()

        XCTAssertEqual(section(of: "Alpha", in: try openPicker(in: one)), "Configured")
    }

    func test_anUnconfiguredWorkspaceOpenElsewhere_isListedUnderOpenElsewhere() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, two) = makeWindows()
        let held = two.activeWorkspaceIDForTesting

        let picker = try openPicker(in: one)
        guard
            let index = picker.rowViews.firstIndex(where: {
                ($0 as? RepoPickerOverlay.RowView)?.running?.window == two.windowID
            })
        else {
            return XCTFail("no row is held by the other window, and both call their first Workspace 1")
        }

        XCTAssertEqual(
            section(at: index, in: picker), "Open Elsewhere",
            "the other window's unconfigured workspace has no config entry to be found through")

        picker.activateRow(at: index)

        XCTAssertEqual(one.workspaceNamesForTesting, ["Workspace 1"], "nothing starts in the asking window")
        XCTAssertEqual(two.workspaceNamesForTesting, ["Workspace 1"], "nor in the one holding it")
        XCTAssertEqual(two.activeWorkspaceIDForTesting, held, "the window holding it is raised on it")
        XCTAssertTrue(pickers(in: one).isEmpty, "the picker closes")
    }

    func test_theFooterReadsSwitchOverAWorkspaceOpenInAnotherWindow() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, two) = makeWindows()
        pressReturn(in: try openPicker(in: two, on: "Alpha"))

        let picker = try openPicker(in: one, on: "Alpha")

        XCTAssertTrue(hintIsShown("switch", in: picker), "↵ crosses to the window holding it")
        XCTAssertFalse(hintIsShown("open", in: picker), "it is not opened a second time")
    }

    func test_aWorkspaceOpenNowhere_stillOpensIntoTheAskingWindow() throws {
        try seedWorkspaces(twoWorkspaces)
        let (one, two) = makeWindows()

        pressReturn(in: try openPicker(in: one, on: "Alpha"))

        XCTAssertEqual(one.workspaceNamesForTesting, ["Workspace 1", "Alpha"])
        XCTAssertEqual(two.workspaceNamesForTesting, ["Workspace 1"])
    }
}
