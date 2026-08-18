import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Drives the Appearance theme picker in a real window, on the accent picker's template: catalog
/// tests cannot see a disconnected callback, and a state-only check passes with a dead control.
final class SettingsThemePickerTests: WindowTestCase {
    private var tempRoot: URL!
    /// Retained: the dropdown's `onChange` captures the section `[weak self]`, so a deallocated
    /// section would silently no-op the write.
    private var section: SettingsFormSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-theme-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        ConfigLoader.defaultRootOverrideForTesting = tempRoot
        AppConfig.reload()  // empty temp root = builtIn: no theme key
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

    /// Mount Appearance and return its theme dropdown. The accent picker beside it reads "Theme
    /// default", so the theme control is the one whose title is not that.
    private func mountThemeDropdown() -> Dropdown {
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
        return dropdowns.first { $0.buttonTitleForTesting != "Theme default" }!
    }

    private func configText() -> String {
        (try? String(
            contentsOf: ConfigLoader.defaultRoot.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    }

    private func writeUserTheme(_ name: String, _ body: String) throws {
        let themes = tempRoot.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try body.write(to: themes.appendingPathComponent(name), atomically: true, encoding: .utf8)
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

    /// The default has no picker row of its own any more, so an absent key has to select its token.
    func test_noThemeKey_showsTheDefaultSelected() {
        let dropdown = mountThemeDropdown()
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Rosé Pine Zen")
        XCTAssertFalse(configText().contains("theme"))
    }

    /// Index 1 is Rosé Pine, so one Down from the default lands on it. Returning to the default
    /// writes its token rather than clearing the key, which is what changed with the nil row.
    func test_selectingATheme_writesTheToken_andReturningWritesTheDefaultsOwn() {
        let dropdown = mountThemeDropdown()
        hostWindow?.makeFirstResponder(dropdown)

        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        dropdown.keyDown(with: key(Self.downKey, arrow: true))
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))

        XCTAssertTrue(configText().contains("theme = rose-pine"), "got: \(configText())")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Rosé Pine")

        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        dropdown.keyDown(with: key(Self.upKey, arrow: true))
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))

        XCTAssertTrue(configText().contains("theme = rose-pine-zen"), "got: \(configText())")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Rosé Pine Zen")
    }

    /// Committing has to move the colors the app paints with, not just the file. Rosé Pine Main's
    /// pine is the slot that separates it from the default, whose palette is Moon's.
    func test_committingASelection_movesTheLiveTheme() {
        let dropdown = mountThemeDropdown()
        hostWindow?.makeFirstResponder(dropdown)
        XCTAssertEqual(Theme.current.terminal.ansi[2], TerminalColor(red: 0x3E, green: 0x8F, blue: 0xB0))

        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        dropdown.keyDown(with: key(Self.downKey, arrow: true))
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))

        XCTAssertEqual(Theme.current.terminal.ansi[2], TerminalColor(red: 0x31, green: 0x74, blue: 0x8F))
    }

    /// A user file named for the default shadows the bundled row in the picker, so resolution has
    /// to honour it with no `theme` key too. Otherwise Settings shows a theme that is not painting.
    func test_aUserFileNamedForTheDefault_isBothSelectedAndActive() throws {
        try writeUserTheme(ThemeCatalog.defaultThemeName, "background = #00ff00\n")
        AppConfig.reload()

        XCTAssertEqual(Theme.current.terminal.background, TerminalColor(red: 0, green: 0xFF, blue: 0))
        // User entries display the raw token, so the shadowing row reads as the filename.
        XCTAssertEqual(mountThemeDropdown().buttonTitleForTesting, ThemeCatalog.defaultThemeName)
    }
}
