import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class SettingsAccentPickerTests: WindowTestCase {
    private var tempRoot: URL!
    private var section: SettingsFormSection?
    private var hostWindow: NSWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-accent-picker-\(UUID().uuidString)", isDirectory: true)
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

    func test_selectingASlot_writesTheToken_thenDefaultClearsIt() {
        let dropdown = mountAccentDropdown()
        hostWindow?.makeFirstResponder(dropdown)

        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        dropdown.keyDown(with: key(Self.downKey, arrow: true))
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))

        XCTAssertTrue(configText().contains("accent-color = black"), "got: \(configText())")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Black")

        dropdown.keyDown(with: key(Self.returnKey, arrow: false))
        dropdown.keyDown(with: key(Self.upKey, arrow: true))
        dropdown.keyDown(with: key(Self.returnKey, arrow: false))

        XCTAssertFalse(configText().contains("accent-color"), "got: \(configText())")
        XCTAssertEqual(dropdown.buttonTitleForTesting, "Theme default")
    }

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

    func test_anExternalThemeChange_reResolvesTheSwatches() throws {
        let dropdown = mountAccentDropdown()
        let before = dropdown.itemsForTesting[1 + AccentSlot.green.ansiIndex]

        let themes = tempRoot.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try "palette = 2=#00ff00\n".write(
            to: themes.appendingPathComponent("greenish"), atomically: true, encoding: .utf8)
        try "theme = greenish\n".write(
            to: tempRoot.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        AppConfig.reload()
        (section as? SettingsAppearanceSection)?.reapplyTheme()

        let after = dropdown.itemsForTesting[1 + AccentSlot.green.ansiIndex]
        XCTAssertEqual(after.note, "#00ff00")
        XCTAssertNotEqual(after.note, before.note)
    }

    func test_everyRowCarriesItsSwatchAndHex() {
        let dropdown = mountAccentDropdown()
        let items = dropdown.itemsForTesting

        XCTAssertEqual(items.count, AccentSlot.allCases.count + 1)
        XCTAssertTrue(items.allSatisfy { $0.swatch != nil })
        XCTAssertEqual(
            items[0].note,
            Theme.current.terminal.ansi[AccentSlot.themeDefault.ansiIndex].hex,
            "the default row's swatch has drifted off themeDefault")
        XCTAssertEqual(
            items[1 + AccentSlot.brightCyan.ansiIndex].note, Theme.current.terminal.ansi[14].hex)
        XCTAssertEqual(items.first { $0.title == "Bright cyan" }?.group, "Bright")
        XCTAssertEqual(items.first { $0.title == "Cyan" }?.group, "Normal")
    }
}
