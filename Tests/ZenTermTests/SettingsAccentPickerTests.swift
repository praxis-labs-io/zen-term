import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Interaction test for the Appearance section's accent picker (ZEN-255), built on the shader
/// picker's template: mount the real section in a window, drive the dropdown with the key events
/// AppKit actually delivers, and assert the token that lands in the config file. A state-only
/// assertion would pass with a dead control.
///
/// The write→reload pipeline is rooted at `ConfigLoader.defaultRoot`; the test points that at a
/// temp dir so it never touches the real config.
final class SettingsAccentPickerTests: WindowTestCase {
    private var tempRoot: URL!
    /// Retained: the dropdown's `onChange` captures the section `[weak self]`, so a deallocated
    /// section would silently no-op the write.
    private var section: SettingsFormSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-accent-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()  // empty temp root = builtIn: no accent-color key
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

    /// Mount Appearance and return its accent dropdown — the one reading "Theme default" (the theme
    /// picker beside it shows a theme name), so the test drives the accent control specifically.
    private func mountAccentDropdown() -> Dropdown {
        let section = SettingsAppearanceSection()
        self.section = section
        let detail = section.makeDetailView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(detail)
        detail.frame = window.contentView!.bounds
        hostWindow = window
        let dropdowns = descendants(of: detail).compactMap { $0 as? Dropdown }
        return dropdowns.first { $0.buttonTitleForTesting == "Theme default" }!
    }

    private func configText() -> String {
        (try? String(
            contentsOf: ConfigLoader.defaultRoot.appendingPathComponent("config"), encoding: .utf8)) ?? ""
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

    func test_defaultsToThemeDefault_withNoKey() {
        let dropdown = mountAccentDropdown()
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Theme default")
        XCTAssertFalse(configText().contains("accent-color"))
    }

    /// Index 1 is the first real slot (`black`), so one Down from the default lands on it.
    func test_selectingASlot_writesTheToken_thenDefaultClearsIt() {
        let dropdown = mountAccentDropdown()
        hostWindow?.makeFirstResponder(dropdown)

        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        dropdown.keyDown(with: key(Self.downKey, arrow: true))
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))

        XCTAssertTrue(configText().contains("accent-color = black"), "got: \(configText())")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Black")

        // Back to "Theme default" clears the key entirely rather than writing magenta.
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        dropdown.keyDown(with: key(Self.upKey, arrow: true))
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))

        XCTAssertFalse(configText().contains("accent-color"), "got: \(configText())")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Theme default")
    }

    /// The whole point of the picker: committing it has to move the color the chrome paints with,
    /// not just the file. `write` → `AppConfig.reload()` → `Theme.current` is the live-apply path.
    func test_committingASelection_movesTheLiveChromeAccent() {
        let dropdown = mountAccentDropdown()
        hostWindow?.makeFirstResponder(dropdown)
        let before = Theme.current.chrome.accent

        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        dropdown.keyDown(with: key(Self.downKey, arrow: true))
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))

        XCTAssertEqual(Theme.current.chrome.accent, Theme.current.terminal.ansi[0])
        XCTAssertNotEqual(Theme.current.chrome.accent, before)
    }

    /// A theme change this card didn't make (another window's Settings, ⌘⌥R after a hand-edit)
    /// arrives as `reapplyTheme()`, which recolors controls but does not re-supply row data. The
    /// accent row's contents ARE theme-derived, so without an explicit refresh its swatches keep
    /// the old palette while the rest of the card recolors: stale, and invisible to a color check.
    func test_anExternalThemeChange_reResolvesTheSwatches() throws {
        let dropdown = mountAccentDropdown()
        let before = dropdown.itemsForTesting[1 + AccentSlot.green.ansiIndex]

        let themes = tempRoot.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try "palette = 2=#00ff00\n".write(
            to: themes.appendingPathComponent("greenish"), atomically: true, encoding: .utf8)
        try "theme = greenish\n".write(
            to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()  // the reload another window's write would cause
        (section as? SettingsAppearanceSection)?.reapplyTheme()

        let after = dropdown.itemsForTesting[1 + AccentSlot.green.ansiIndex]
        XCTAssertEqual(after.note, "#00ff00")
        XCTAssertNotEqual(after.note, before.note)
    }

    /// Every row carries the swatch that makes a hue name honest, and the hex of what the theme
    /// actually put in that slot. Dropping either leaves the user picking names blind.
    func test_everyRowCarriesItsSwatchAndHex() {
        let dropdown = mountAccentDropdown()
        let items = dropdown.itemsForTesting

        XCTAssertEqual(items.count, AccentSlot.allCases.count + 1)
        XCTAssertTrue(items.allSatisfy { $0.swatch != nil })
        XCTAssertEqual(items[0].note, Theme.current.terminal.ansi[5].hex)  // the default's own color
        XCTAssertEqual(
            items[1 + AccentSlot.brightCyan.ansiIndex].note, Theme.current.terminal.ansi[14].hex)
        XCTAssertEqual(items.first { $0.title == "Bright cyan" }?.group, "Bright")
        XCTAssertEqual(items.first { $0.title == "Cyan" }?.group, "Normal")
    }
}
