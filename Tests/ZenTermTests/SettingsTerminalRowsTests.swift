import AppKit
import XCTest

@testable import ZenTerm

/// Interaction tests for the Terminal section's two newest segmented rows: mount the real section in
/// a window, drive the real control the way a click would, and read the value that lands in the
/// config file. A state-only assertion passes while the control is dead.
///
/// `tab-inherit-cwd` is the one that most needs driving. Its options are Home/Current, so index 1 is
/// `true` where every other row here is On/Off with index 0 as `true`. The parser and writer tests
/// both stay green if that row writes the boolean backwards.
///
/// Rows are addressed by config key, not by position: the section holds five segmented controls and
/// an ordinal would quietly point at a different row the moment one is inserted above.
final class SettingsTerminalRowsTests: WindowTestCase {
    private var tempRoot: URL!
    /// Retained for the test's lifetime: a row's write closure captures the section `[weak self]`,
    /// so a deallocated section silently no-ops the write.
    private var section: SettingsTerminalSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-terminal-rows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()  // GeneralConfig.current now reflects the empty temp root (= builtIn)

        // Built after the reload: every row reads its starting selection from `GeneralConfig.current`.
        let section = SettingsTerminalSection()
        let detail = section.makeDetailView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(detail)
        detail.frame = window.contentView!.bounds
        self.section = section
        hostWindow = window
    }

    override func tearDownWithError() throws {
        section = nil
        hostWindow = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()  // restore the process's real config state
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    /// The mounted segmented control the config key owns.
    private func segment(_ key: String) throws -> SegmentedControl {
        try XCTUnwrap(
            section?.controlForTesting(key) as? SegmentedControl,
            "the Terminal section should mount a segmented row for \(key)")
    }

    private func configText() -> String {
        (try? String(
            contentsOf: ConfigLoader.defaultRoot.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    }

    // MARK: font-thicken

    func test_fontThicken_defaultsToOff() throws {
        let thicken = try segment("font-thicken")
        XCTAssertEqual(thicken.selectedIndex, 1, "off is the shipped default, and Off is index 1")
    }

    func test_fontThicken_selectingOn_thenOff_writesTrueThenFalse() throws {
        let thicken = try segment("font-thicken")

        thicken.select(0)  // On
        XCTAssertTrue(configText().contains("font-thicken = true"), "got: \(configText())")

        thicken.select(1)  // Off
        XCTAssertTrue(configText().contains("font-thicken = false"), "got: \(configText())")
    }

    // MARK: tab-inherit-cwd

    func test_tabInheritCWD_defaultsToHome() throws {
        let directory = try segment("tab-inherit-cwd")
        XCTAssertEqual(directory.selectedIndex, 0, "home is the shipped default, and Home is index 0")
    }

    /// The reversed mapping, driven end to end. Current is index 1 and must write `true`; picking it
    /// and getting `false` is the bug no other test in the suite can see.
    func test_tabInheritCWD_selectingCurrent_thenHome_writesTrueThenFalse() throws {
        let directory = try segment("tab-inherit-cwd")

        directory.select(1)  // Current
        XCTAssertTrue(configText().contains("tab-inherit-cwd = true"), "got: \(configText())")

        directory.select(0)  // Home
        XCTAssertTrue(configText().contains("tab-inherit-cwd = false"), "got: \(configText())")
    }

    /// What the row wrote has to survive the parser, which is the half a token test cannot see: the
    /// row could write a value the parser reads back as the opposite and both halves would pass.
    func test_tabInheritCWD_selectingCurrent_reloadsAsInherit() throws {
        let directory = try segment("tab-inherit-cwd")

        directory.select(1)  // Current
        AppConfig.reload()

        XCTAssertTrue(GeneralConfig.current.tabInheritCWD)
    }
}
