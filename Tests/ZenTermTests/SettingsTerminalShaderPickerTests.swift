import AppKit
import XCTest

@testable import ZenTerm

/// Interaction test for the Terminal section's custom-shader picker: mount the real section in a
/// window, drive the dropdown with the key events AppKit actually delivers (Return opens/commits,
/// arrows move the highlight), and assert the token that lands in the config file. A state-only
/// assertion would pass while the control is dead — exactly how a broken dropdown once shipped past
/// two reviews (ZEN-78 lesson) — so this drives the control itself, through its real keyDown.
///
/// The picker lives in Terminal (not Appearance) because a shader only affects the terminal surface.
/// The write→reload pipeline is rooted at `ConfigLoader.defaultRoot`; the test points that at a temp
/// dir so it never touches the real config.
final class SettingsTerminalShaderPickerTests: XCTestCase {
    private var tempRoot: URL!
    /// Retained: the dropdown's `onChange` captures the section `[weak self]`, so a deallocated
    /// section would silently no-op the write.
    private var section: SettingsFormSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-shader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reloadBlocking()  // empty temp root = builtIn: no shader
    }

    override func tearDownWithError() throws {
        section = nil
        hostWindow = nil
        drainConfigWrites()  // a write still in flight would land in the real config root
        ConfigLoader.defaultRootOverrideForTesting = nil
        AppConfig.reloadBlocking()
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Mount the section and return its shader dropdown — the one whose button reads "Off" by
    /// default (the Terminal section's only dropdown), so the test drives the shader control.
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

    /// Wait for the pending write, then read the sandboxed config file. Picking a shader writes off
    /// the main thread (ZEN-17), so reading without waiting reports the file from before the pick.
    private func configText() -> String {
        drainConfigWrites()
        let url = ConfigLoader.defaultRoot.appendingPathComponent("config")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func key(_ keyCode: UInt16, arrow: Bool) -> NSEvent {
        // Arrows carry the .function/.numericPad pair AppKit always attaches; Return is a plain key.
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

        // Open (Return), move down to "Cursor Warp" (index 1), commit (Return).
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        dropdown.keyDown(with: key(Self.downKey, arrow: true))
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))

        XCTAssertTrue(
            configText().contains("cursor-shader = cursor_warp"), "got: \(configText())")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Cursor Warp")

        // Back to Off (Return to open, Up to index 0, Return) clears the key entirely.
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        dropdown.keyDown(with: key(Self.upKey, arrow: true))
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))

        XCTAssertFalse(configText().contains("cursor-shader"), "got: \(configText())")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Off")
    }
}
