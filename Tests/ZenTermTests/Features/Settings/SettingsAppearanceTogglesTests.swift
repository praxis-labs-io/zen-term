import AppKit
import XCTest

@testable import ZenTerm

final class SettingsAppearanceTogglesTests: WindowTestCase {
    private var tempRoot: URL!
    private var section: SettingsAppearanceSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-appearance-toggles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()
    }

    override func tearDownWithError() throws {
        section = nil
        hostWindow = nil
        ConfigReset.toBuiltIn()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func configText() -> String {
        (try? String(contentsOf: tempRoot.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    }

    private func mountToggle(_ key: String) throws -> ToggleSwitch {
        let section = SettingsAppearanceSection()
        self.section = section
        let detail = section.makeDetailView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.borderless], backing: .buffered, defer: false)
        hostWindow = window
        window.contentView?.addSubview(detail)
        detail.frame = window.contentView!.bounds
        return try XCTUnwrap(section.controlForTesting(key) as? ToggleSwitch, "no switch row for \(key)")
    }

    private func pressSpace(_ toggle: ToggleSwitch) {
        hostWindow?.makeFirstResponder(toggle)
        toggle.keyDown(
            with: NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false,
                keyCode: 49)!)
    }

    func test_reduceMotion_unset_followsTheSystem() throws {
        Motion.isReduceMotionEnabled = { true }

        XCTAssertTrue(try mountToggle("reduce-motion").isOn)
    }

    func test_reduceMotion_flippingOffThenOn_pinsEachValue() throws {
        Motion.isReduceMotionEnabled = { true }
        let toggle = try mountToggle("reduce-motion")

        pressSpace(toggle)
        XCTAssertTrue(configText().contains("reduce-motion = off"), "got: \(configText())")

        pressSpace(toggle)
        XCTAssertTrue(configText().contains("reduce-motion = on"), "got: \(configText())")
    }

    func test_windowButtons_switchingOff_writesFalse() throws {
        let toggle = try mountToggle("window-chrome")
        XCTAssertTrue(toggle.isOn)

        pressSpace(toggle)

        XCTAssertTrue(configText().contains("window-chrome = false"), "got: \(configText())")
    }
}
