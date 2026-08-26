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

    /// Steps from the default to whichever theme the alphabetical list puts after it. Resolved from
    /// the catalog rather than hardcoded: the list is sorted by display name, so a magic index means
    /// a different theme every time a theme is added.
    func test_selectingATheme_writesTheToken_andReturningWritesTheDefaultsOwn() throws {
        let entries = ThemeCatalog.entries(configRoot: tempRoot)
        let defaultIndex = try XCTUnwrap(entries.firstIndex { $0.name == ThemeCatalog.defaultThemeName })
        XCTAssertTrue(entries.indices.contains(defaultIndex + 1), "the default is last; nothing to step to")
        let next = entries[defaultIndex + 1]

        let dropdown = mountThemeDropdown()
        hostWindow?.makeFirstResponder(dropdown)

        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        dropdown.keyDown(with: key(Self.downKey, arrow: true))
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))

        XCTAssertTrue(configText().contains("theme = \(next.name)"), "got: \(configText())")
        XCTAssertEqual(dropdown.buttonTitleForTesting, next.displayName)

        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        dropdown.keyDown(with: key(Self.upKey, arrow: true))
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))

        XCTAssertTrue(configText().contains("theme = rose-pine-zen"), "got: \(configText())")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Rosé Pine Zen")
    }

    /// Committing has to move the colors the app paints with, not just the file. Asserts the live
    /// palette lands on the *stepped-to* theme's own values, read from its file, so the check holds
    /// whatever the alphabetical list puts next to the default.
    func test_committingASelection_movesTheLiveTheme() throws {
        let entries = ThemeCatalog.entries(configRoot: tempRoot)
        let defaultIndex = try XCTUnwrap(entries.firstIndex { $0.name == ThemeCatalog.defaultThemeName })
        XCTAssertTrue(entries.indices.contains(defaultIndex + 1), "the default is last; nothing to step to")
        let next = entries[defaultIndex + 1]
        var general = GeneralConfig.builtIn
        general.themeName = next.name
        let expected = ConfigLoader.loadAppTheme(configRoot: tempRoot, general: general).terminal

        let dropdown = mountThemeDropdown()
        hostWindow?.makeFirstResponder(dropdown)
        XCTAssertEqual(Theme.current.terminal.ansi[2], TerminalColor(red: 0x3E, green: 0x8F, blue: 0xB0))

        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        dropdown.keyDown(with: key(Self.downKey, arrow: true))
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))

        XCTAssertEqual(Theme.current.terminal.ansi, expected.ansi)
        XCTAssertEqual(Theme.current.terminal.background, expected.background)
        XCTAssertNotEqual(Theme.current.terminal.ansi[2], TerminalColor(red: 0x3E, green: 0x8F, blue: 0xB0))
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
