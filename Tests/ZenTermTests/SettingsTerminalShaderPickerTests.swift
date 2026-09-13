import AppKit
import XCTest

@testable import ZenTerm

final class SettingsTerminalShaderPickerTests: WindowTestCase {
    private var tempRoot: URL!
    private var section: SettingsFormSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-shader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()
    }

    override func tearDownWithError() throws {
        section = nil
        hostWindow = nil
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reload()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func mountShaderDropdown() -> Dropdown {
        let section = SettingsTerminalSection()
        self.section = section
        let detail = section.makeDetailView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(detail)
        detail.frame = window.contentView!.bounds
        hostWindow = window
        let dropdowns = descendants(of: detail).compactMap { $0 as? Dropdown }
        return dropdowns.first { $0.buttonTitleForTesting == "Off" }!
    }

    private func configText() -> String {
        (try? String(
            contentsOf: ConfigLoader.defaultRoot.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    }

    private func key(_ keyCode: UInt16, arrow: Bool) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: arrow ? [.function, .numericPad] : [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode)!
    }
    private static let returnKey: UInt16 = 36
    private static let downKey: UInt16 = 125
    private static let upKey: UInt16 = 126

    func test_defaultsToOff_withNoShaderKey() {
        let dropdown = mountShaderDropdown()
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Off")
        XCTAssertFalse(configText().contains("cursor-shader"))
    }

    func test_selectingCursorWarp_writesTheToken_thenOffClearsIt() {
        let dropdown = mountShaderDropdown()
        hostWindow?.makeFirstResponder(dropdown)

        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        dropdown.keyDown(with: key(Self.downKey, arrow: true))
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))

        XCTAssertTrue(
            configText().contains("cursor-shader = cursor_warp"), "got: \(configText())")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Cursor Warp")

        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        dropdown.keyDown(with: key(Self.upKey, arrow: true))
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))

        XCTAssertFalse(configText().contains("cursor-shader"), "got: \(configText())")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Off")
    }
}
