import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class RepoPickerHostRowTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var root: URL!
    private let devbox = SSHHostID(alias: "devbox")
    private let build = SSHHostID(alias: "build")

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        var config = GeneralConfig.builtIn
        config.sshHosts = [SSHHostEntry(alias: devbox.alias, name: "Dev Box"), SSHHostEntry(alias: build.alias)]
        GeneralConfig.setCurrentForTesting(config)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-picker-hosts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = root
        try "[Alpha]\npath = ~/Dev/alpha\n".write(
            to: root.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.map { AttentionCenter.shared.forget(windowID: $0.windowID) }
        controller = nil
        for host in [devbox, build] { SSHHostStatusCenter.shared.setReachable(false, host: host) }
        ConfigLoader.defaultRootOverrideForTesting = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        c.mountAndStart()
        controller = c
        return c
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func pickerIn(_ c: WindowController) -> RepoPickerOverlay? {
        descendants(of: c.window.contentView!).compactMap { $0 as? RepoPickerOverlay }.first
    }

    private func openPicker(in c: WindowController) throws -> RepoPickerOverlay {
        c.handle(.toggleRepoPicker)
        waitUntil(pickerIn(c) != nil, "the picker to be presented")
        return try XCTUnwrap(pickerIn(c))
    }

    private func searchField(of picker: RepoPickerOverlay) throws -> NSTextField {
        try XCTUnwrap(
            descendants(of: picker).compactMap { $0 as? NSTextField }
                .first { ($0.delegate as? PaletteOverlay) === picker })
    }

    private func type(_ text: String, into picker: RepoPickerOverlay, in c: WindowController) throws {
        let field = try searchField(of: picker)
        XCTAssertTrue(c.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func pressReturn(in picker: RepoPickerOverlay) throws {
        _ = picker.control(
            try searchField(of: picker), textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    private func hostRows(of picker: RepoPickerOverlay) -> [RepoPickerOverlay.HostRowView] {
        picker.rowViews.compactMap { $0 as? RepoPickerOverlay.HostRowView }
    }

    func test_hosts_followTheWorkspaces_inConfigOrder_namedWithTheirStatus() throws {
        SSHHostStatusCenter.shared.setReachable(true, host: build)
        let picker = try openPicker(in: makeWindow())

        XCTAssertEqual(hostRows(of: picker).map(\.title), ["Dev Box", "build"])
        XCTAssertEqual(hostRows(of: picker).map(\.detail), ["Offline", "Online"])
        let titles = picker.rowViews.compactMap { ($0 as? ListRow)?.title }
        let alpha = try XCTUnwrap(titles.firstIndex(of: "Alpha"))
        let firstHost = try XCTUnwrap(titles.firstIndex(of: "Dev Box"))
        let add = try XCTUnwrap(titles.firstIndex(of: "Add Workspace…"))
        XCTAssertLessThan(alpha, firstHost)
        XCTAssertLessThan(firstHost, add)
    }

    func test_aQuery_findsAHostByItsAlias_underItsName() throws {
        let c = makeWindow()
        let picker = try openPicker(in: c)

        try type("devbox", into: picker, in: c)

        XCTAssertEqual(hostRows(of: picker).map(\.title), ["Dev Box"])
    }

    func test_returnOnAHost_closesThePicker_andShowsItsConnectScreen() throws {
        let c = makeWindow()
        let picker = try openPicker(in: c)
        try type("build", into: picker, in: c)

        try pressReturn(in: picker)

        XCTAssertNil(pickerIn(c), "the picker closes")
        XCTAssertEqual(c.selectedHostForTesting, build)
        XCTAssertEqual(c.connectViewForTesting?.host, build)
    }

    func test_aStatusChange_whileOpen_updatesTheRowInPlace() throws {
        let picker = try openPicker(in: makeWindow())
        let row = try XCTUnwrap(hostRows(of: picker).first)
        XCTAssertEqual(row.detail, "Offline")

        SSHHostStatusCenter.shared.setReachable(true, host: devbox)

        XCTAssertEqual(row.detail, "Online")
        XCTAssertTrue(hostRows(of: picker).first === row, "the row is kept, not rebuilt")
    }

    func test_anExactHostAlias_outranksALooserWorkspaceMatch() throws {
        try "[Builder]\npath = ~/Dev/builder\n".write(
            to: root.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
        let c = makeWindow()
        let picker = try openPicker(in: c)

        try type("build", into: picker, in: c)

        let selected = picker.rowViews[picker.selected] as? RepoPickerOverlay.HostRowView
        XCTAssertEqual(selected?.host, build)
    }

    func test_theHostOnScreen_offersSwitch_notOpen() throws {
        let c = makeWindow()
        c.selectHostForTesting(devbox)
        let picker = try openPicker(in: c)

        try type("Dev Box", into: picker, in: c)

        XCTAssertEqual(picker.barHintsForTesting.first?.label, "Switch")
    }

    func test_theHostOnScreen_readsCurrent() throws {
        let c = makeWindow()
        c.selectHostForTesting(devbox)

        let picker = try openPicker(in: c)

        XCTAssertEqual(hostRows(of: picker).first?.accessibilityValue() as? String, "Offline, Current")
    }
}
