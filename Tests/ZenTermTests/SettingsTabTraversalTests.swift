import AppKit
import XCTest

@testable import ZenTerm

/// Tab traversal through the Settings card (ZEN-146). Tab was never missing — it was half-wired:
/// four stops ignored it, Shift-Tab teleported to the nav instead of retreating one stop, and
/// `SettingsNavRow` discarded the shift payload so Shift-Tab *also* entered the detail pane.
///
/// These drive a real `NSEvent` at a mounted stop and assert `window.firstResponder` moved. No
/// existing test did that — they unit-test the decoder or set the first responder directly, which
/// is exactly how a stop with no `.tab` case at all passed as "wired".
final class SettingsTabTraversalTests: XCTestCase {
    private var tempRoot: URL!
    private var window: NSWindow?
    /// The mounted section, retained the way the Settings card retains it: the Workspaces section
    /// fills its rows in when the config load lands, and a released section drops that.
    private var section: (any SettingsSection)?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-tab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        window = nil
        section = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    // MARK: harness

    private func seed(_ text: String) throws {
        try text.write(to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Tab (or Shift-Tab) as a real key event: keyCode 48, shift in the modifier flags — the same
    /// thing `KeyboardFocus.key(for:)` decodes at runtime.
    private func tabEvent(shift: Bool) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: 48)!
    }

    /// Focus `stop`, then send Tab/Shift-Tab to it exactly as AppKit would dispatch to a first
    /// responder, and report where focus landed.
    private func tab(from stop: NSView, shift: Bool = false) -> NSResponder? {
        window!.makeFirstResponder(stop)
        stop.keyDown(with: tabEvent(shift: shift))
        return window!.firstResponder
    }

    @discardableResult
    private func mount(_ detail: NSView) -> NSView {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView?.addSubview(detail)
        detail.frame = win.contentView!.bounds
        window = win
        return detail
    }

    private let twoFloats = """
        float = title:dev key:cmd+shift+d command:vim
        float = title:top key:cmd+shift+t command:htop
        """

    // MARK: Tools rows — a stop that ignored Tab entirely

    func test_tab_fromToolFloatRow_advancesToTheNextRow() throws {
        try seed(twoFloats)
        let section = SettingsToolsSection()
        let detail = mount(section.makeDetailView())
        let rows = descendants(of: detail).compactMap { $0 as? ToolFloatRow }

        XCTAssertIdentical(tab(from: rows[0]), rows[1], "Tab advances to the next row")
    }

    func test_shiftTab_fromToolFloatRow_retreatsOneStop_notToTheNav() throws {
        try seed(twoFloats)
        let section = SettingsToolsSection()
        var exitedToNav = 0
        section.onExitToNav = { exitedToNav += 1 }
        let detail = mount(section.makeDetailView())
        let rows = descendants(of: detail).compactMap { $0 as? ToolFloatRow }

        let landed = tab(from: rows[1], shift: true)

        XCTAssertIdentical(landed, rows[0], "Shift-Tab retreats one stop")
        XCTAssertEqual(exitedToNav, 0, "Shift-Tab mid-list must not teleport to the nav")
    }

    func test_shiftTab_fromFirstStop_exitsToTheNav() throws {
        try seed(twoFloats)
        let section = SettingsToolsSection()
        var exitedToNav = 0
        section.onExitToNav = { exitedToNav += 1 }
        let detail = mount(section.makeDetailView())
        let rows = descendants(of: detail).compactMap { $0 as? ToolFloatRow }

        _ = tab(from: rows[0], shift: true)

        XCTAssertEqual(exitedToNav, 1, "Shift-Tab from the first stop exits to the nav, like Left")
    }

    /// `KeyboardFocus.step` clamps for arrows; Tab wraps. A Tab loop that stops dead at the last
    /// stop reads as broken.
    func test_tab_fromLastStop_wrapsToTheFirst() throws {
        try seed(twoFloats)
        let section = SettingsToolsSection()
        let detail = mount(section.makeDetailView())
        let rows = descendants(of: detail).compactMap { $0 as? ToolFloatRow }
        let addButton = try XCTUnwrap(section.detailStops().last as? AppButton)

        XCTAssertIdentical(tab(from: addButton), rows[0], "Tab from the last stop wraps to the first")
    }

    // MARK: Workspaces rows — the other stop that ignored Tab

    func test_tab_fromWorkspaceRow_advancesToTheNextRow() throws {
        let dirA = try makeDir("alpha")
        let dirB = try makeDir("beta")
        try seedWorkspaces(
            """
            [Alpha]
            path = \(dirA.path)

            [Beta]
            path = \(dirB.path)
            """)
        let section = SettingsWorkspacesSection()
        self.section = section
        let detail = mount(section.makeDetailView())
        // The `workspaces` file is read off the main thread, so the rows land after the mount.
        waitUntil(
            descendants(of: detail).compactMap { $0 as? WorkspaceRow }.count == 2,
            "a row per seeded workspace")
        let rows = descendants(of: detail).compactMap { $0 as? WorkspaceRow }

        XCTAssertIdentical(tab(from: rows[0]), rows[1], "Tab advances to the next row")
    }

    // MARK: Keybinds chips — a stop that ignored Tab

    func test_tab_fromKeybindChip_advancesToTheNextChip() throws {
        try seed("")
        let section = SettingsKeybindsSection(capturer: nil)
        let detail = mount(section.makeDetailView())
        let chips = descendants(of: detail).compactMap { $0 as? KeybindChip }
        XCTAssertGreaterThan(chips.count, 1, "expected several keybind rows")

        XCTAssertIdentical(tab(from: chips[0]), chips[1], "Tab advances to the next chip")
    }

    func test_shiftTab_fromKeybindChip_retreatsOneStop_notToTheNav() throws {
        try seed("")
        let section = SettingsKeybindsSection(capturer: nil)
        var exitedToNav = 0
        section.onExitToNav = { exitedToNav += 1 }
        let detail = mount(section.makeDetailView())
        let chips = descendants(of: detail).compactMap { $0 as? KeybindChip }

        let landed = tab(from: chips[1], shift: true)

        XCTAssertIdentical(landed, chips[0], "Shift-Tab retreats one chip")
        XCTAssertEqual(exitedToNav, 0, "Shift-Tab mid-list must not teleport to the nav")
    }

    // MARK: the icon picker — a stop that ignored Tab

    /// Closed, the picker is an ordinary stop and Tab moves on. Open, the grid keeps consuming
    /// everything (Tab included) — arrows drive the highlight there.
    func test_tab_fromIconPicker_advancesWhenClosed_andIsConsumedWhenOpen() {
        let picker = IconPickerField(selected: IconCatalog.defaultSymbol)
        var tabbed = 0
        picker.onTab = { tabbed += 1 }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        host.addSubview(picker)
        mount(host)

        picker.keyDown(with: tabEvent(shift: false))
        XCTAssertEqual(tabbed, 1, "closed, Tab moves to the next stop")

        picker.openForTesting()
        picker.keyDown(with: tabEvent(shift: false))
        XCTAssertEqual(tabbed, 1, "open, the grid consumes Tab")
        XCTAssertTrue(picker.isPopoverOpen)
    }

    // MARK: the nav row — Shift-Tab retreats via its own (wrapping) path, not aliased to Up

    func test_navRow_tabEntersDetail_shiftTabRetreatsViaBacktab_notUp() {
        let row = SettingsNavRow(title: "Test", onActivate: {})
        var entered = 0
        var uped = 0
        var backtabbed = 0
        row.onEnterDetail = { entered += 1 }
        row.onArrowUp = { uped += 1 }
        row.onBacktab = { backtabbed += 1 }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        host.addSubview(row)
        mount(host)

        row.keyDown(with: tabEvent(shift: false))
        XCTAssertEqual(entered, 1)
        XCTAssertEqual(backtabbed, 0)

        row.keyDown(with: tabEvent(shift: true))
        XCTAssertEqual(
            entered, 1, "Shift-Tab must not enter the detail pane — the shift payload was discarded")
        XCTAssertEqual(backtabbed, 1, "Shift-Tab retreats via onBacktab, which wraps at the first row")
        XCTAssertEqual(uped, 0, "Shift-Tab is no longer aliased to Up — Up clamps, Shift-Tab wraps")
    }

    // MARK: helpers

    private func makeDir(_ name: String) throws -> URL {
        let dir = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func seedWorkspaces(_ text: String) throws {
        try text.write(
            to: tempRoot.appendingPathComponent("workspaces"), atomically: true, encoding: .utf8)
        AppConfig.reload()
    }
}
