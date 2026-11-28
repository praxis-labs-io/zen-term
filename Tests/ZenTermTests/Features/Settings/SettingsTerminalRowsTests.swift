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

    private func toggle(_ key: String) throws -> ToggleSwitch {
        try XCTUnwrap(
            section?.controlForTesting(key) as? ToggleSwitch,
            "the Terminal section should mount a switch row for \(key)")
    }

    private func click(_ toggle: ToggleSwitch) throws {
        hostWindow?.contentView?.layoutSubtreeIfNeeded()
        let point = toggle.convert(NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: hostWindow?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1))
            type == .leftMouseDown ? toggle.mouseDown(with: event) : toggle.mouseUp(with: event)
        }
    }

    private func configText() -> String {
        (try? String(
            contentsOf: ConfigLoader.defaultRoot.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    }

    func test_fontThicken_defaultsToOff() throws {
        XCTAssertFalse(try toggle("font-thicken").isOn, "off is the shipped default")
    }

    func test_fontThicken_switchingOn_thenOff_writesTrueThenFalse() throws {
        let thicken = try toggle("font-thicken")

        try click(thicken)
        XCTAssertTrue(configText().contains("font-thicken = true"), "got: \(configText())")

        try click(thicken)
        XCTAssertTrue(configText().contains("font-thicken = false"), "got: \(configText())")
    }

    func test_fontThicken_slidesItsKnob_throughTheRowRefresh() throws {
        Motion.isReduceMotionEnabled = { false }
        let thicken = try toggle("font-thicken")

        try click(thicken)

        XCTAssertTrue(thicken.isKnobSlidingForTesting, "the row's refresh snapped the knob to its end")
    }

    func test_aSwitchRow_namesItsSwitchForVoiceOver() throws {
        XCTAssertEqual(try toggle("font-thicken").accessibilityLabel(), "Thicken")
    }

    func test_aFailedWrite_putsTheSwitchBack() throws {
        let thicken = try toggle("font-thicken")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tempRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempRoot.path) }

        try click(thicken)

        XCTAssertFalse(thicken.isOn, "the switch shows a value that was never saved")
        XCTAssertFalse(GeneralConfig.current.fontThicken)
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
