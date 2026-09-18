import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class SettingsThemePickerTests: WindowTestCase {
    private var tempRoot: URL!
    private var section: SettingsFormSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-theme-picker-\(UUID().uuidString)", isDirectory: true)
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

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

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
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: arrow ? [.function, .numericPad] : [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode)!
    }
    private static let returnKey: UInt16 = 36
    private static let downKey: UInt16 = 125
    private static let upKey: UInt16 = 126

    func test_noThemeKey_showsTheDefaultSelected() {
        let dropdown = mountThemeDropdown()
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Rosé Pine Zen")
        XCTAssertFalse(configText().contains("theme"))
    }

    func test_selectingATheme_writesTheToken_andReturningWritesTheDefaultsOwn() throws {
        let entries = ThemeCatalog.entries(configRoot: tempRoot)
        let defaultIndex = try XCTUnwrap(entries.firstIndex { $0.name == ThemeCatalog.defaultThemeName })
        XCTAssertTrue(entries.indices.contains(defaultIndex + 1), "the default is last; nothing to step to")
        let next = entries[defaultIndex + 1]

        let dropdown = mountThemeDropdown()
        hostWindow?.makeFirstResponder(dropdown)

        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.moveDown(_:)))
        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.insertNewline(_:)))

        XCTAssertTrue(configText().contains("theme = \(next.name)"), "got: \(configText())")
        XCTAssertEqual(dropdown.buttonTitleForTesting, next.displayName)

        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.moveUp(_:)))
        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.insertNewline(_:)))

        XCTAssertTrue(configText().contains("theme = rose-pine-zen"), "got: \(configText())")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Rosé Pine Zen")
    }

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
        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.moveDown(_:)))
        _ = dropdown.fieldCommandForTesting(#selector(NSResponder.insertNewline(_:)))

        XCTAssertEqual(Theme.current.terminal.ansi, expected.ansi)
        XCTAssertEqual(Theme.current.terminal.background, expected.background)
        XCTAssertNotEqual(Theme.current.terminal.ansi[2], TerminalColor(red: 0x3E, green: 0x8F, blue: 0xB0))
    }

    func test_aUserFileNamedForTheDefault_isBothSelectedAndActive() throws {
        try writeUserTheme(ThemeCatalog.defaultThemeName, "background = #00ff00\n")
        AppConfig.reload()

        XCTAssertEqual(Theme.current.terminal.background, TerminalColor(red: 0, green: 0xFF, blue: 0))
        XCTAssertEqual(mountThemeDropdown().buttonTitleForTesting, ThemeCatalog.defaultThemeName)
    }
}
