import AppKit
import XCTest

@testable import ZenTerm

final class SettingsTerminalRowsTests: WindowTestCase {
    private var tempRoot: URL!
    private var section: SettingsTerminalSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-terminal-rows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()

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
        ConfigReset.toBuiltIn()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func segment(_ key: String) throws -> SegmentedControl {
        try XCTUnwrap(
            section?.controlForTesting(key) as? SegmentedControl,
            "the Terminal section should mount a segmented row for \(key)")
    }

    private func configText() -> String {
        (try? String(
            contentsOf: ConfigLoader.defaultRoot.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    }

    func test_fontThicken_defaultsToOff() throws {
        let thicken = try segment("font-thicken")
        XCTAssertEqual(thicken.selectedIndex, 1, "off is the shipped default, and Off is index 1")
    }

    func test_fontThicken_selectingOn_thenOff_writesTrueThenFalse() throws {
        let thicken = try segment("font-thicken")

        thicken.select(0)
        XCTAssertTrue(configText().contains("font-thicken = true"), "got: \(configText())")

        thicken.select(1)
        XCTAssertTrue(configText().contains("font-thicken = false"), "got: \(configText())")
    }

    func test_tabInheritCWD_defaultsToHome() throws {
        let directory = try segment("tab-inherit-cwd")
        XCTAssertEqual(directory.selectedIndex, 0, "home is the shipped default, and Home is index 0")
    }

    func test_tabInheritCWD_selectingCurrent_thenHome_writesTrueThenFalse() throws {
        let directory = try segment("tab-inherit-cwd")

        directory.select(1)
        XCTAssertTrue(configText().contains("tab-inherit-cwd = true"), "got: \(configText())")

        directory.select(0)
        XCTAssertTrue(configText().contains("tab-inherit-cwd = false"), "got: \(configText())")
    }

    func test_tabInheritCWD_selectingCurrent_reloadsAsInherit() throws {
        let directory = try segment("tab-inherit-cwd")

        directory.select(1)
        AppConfig.reload()

        XCTAssertTrue(GeneralConfig.current.tabInheritCWD)
    }
}
