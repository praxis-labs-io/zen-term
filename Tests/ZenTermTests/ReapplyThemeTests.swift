import AppKit
import XCTest

@testable import ZenTerm

final class ReapplyThemeTests: WindowTestCase {
    private var originalTheme: AppTheme!
    private var tempRoots: [URL] = []
    private var originalConfig: GeneralConfig!

    override func setUp() {
        super.setUp()
        originalTheme = Theme.current
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        Theme.setCurrentForTesting(originalTheme)
        GeneralConfig.setCurrentForTesting(originalConfig)
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
        try super.tearDownWithError()
    }

    private func makeAlternateTheme() throws -> AppTheme {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-reapply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempRoots.append(dir)
        try """
        background = #010101
        foreground = #fefefe
        palette = 1=#ff0000
        palette = 5=#00ff00
        # The accent slot, named from the constant rather than pinned: this fixture used to
        # move palette 5 because that was the accent, and went blind when the default moved.
        palette = \(AccentSlot.themeDefault.ansiIndex)=#00ffff
        """.write(to: dir.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        return ConfigLoader.loadAppTheme(configRoot: dir, general: .builtIn)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        return window
    }

    private func attributedTitleColor(_ button: AppButton) -> NSColor? {
        guard button.attributedTitle.length > 0 else { return nil }
        return button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    func test_reapplyTheme_recolorsAppButton() throws {
        let button = AppButton(title: "Add", variant: .primary) {}
        button.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(button)
        button.frame = NSRect(x: 0, y: 0, width: 80, height: 26)

        let colorBefore = attributedTitleColor(button)
        XCTAssertNotNil(colorBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        button.reapplyTheme()

        XCTAssertNotEqual(colorBefore, attributedTitleColor(button))
    }

    func test_reapplyTheme_recolorsFieldBox() throws {
        let field = FieldBox(placeholder: "Name")
        field.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(field)
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 30)

        let colorBefore = field.field.textColor

        Theme.setCurrentForTesting(try makeAlternateTheme())
        field.reapplyTheme()

        XCTAssertNotEqual(colorBefore, field.field.textColor)
    }

    private func placeholderColor(_ field: NSTextField) -> NSColor? {
        guard let placeholder = field.placeholderAttributedString, placeholder.length > 0 else {
            return nil
        }
        return placeholder.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    func test_reapplyTheme_recolorsFieldBoxPlaceholder() throws {
        let field = FieldBox(placeholder: "0.82")
        field.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(field)
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 30)

        let colorBefore = placeholderColor(field.field)
        XCTAssertNotNil(colorBefore)
        XCTAssertEqual(colorBefore, Theme.current.chrome.ink(.muted))

        Theme.setCurrentForTesting(try makeAlternateTheme())
        field.reapplyTheme()

        let colorAfter = placeholderColor(field.field)
        XCTAssertEqual(colorAfter, Theme.current.chrome.ink(.muted))
        XCTAssertNotEqual(colorBefore, colorAfter)
    }

    func test_reapplyTheme_recolorsDropdown() throws {
        let items = [DropdownItem(title: "One", group: nil, note: nil, isSelected: true)]
        let dropdown = Dropdown(items: items, selectedIndex: 0) { _ in }
        dropdown.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(dropdown)
        dropdown.frame = NSRect(x: 0, y: 0, width: 200, height: 30)

        let colorBefore = dropdown.layer?.backgroundColor

        Theme.setCurrentForTesting(try makeAlternateTheme())
        dropdown.reapplyTheme()

        XCTAssertNotEqual(colorBefore, dropdown.layer?.backgroundColor)
    }

    func test_reapplyTheme_recolorsSegmentedControl() throws {
        let control = SegmentedControl(options: ["A", "B"], selectedIndex: 0) { _ in }
        control.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(control)
        control.frame = NSRect(x: 0, y: 0, width: 100, height: 26)

        guard
            let firstSegment = control.subviews.compactMap({ $0 as? NSStackView }).first?.arrangedSubviews
                .compactMap({ $0 as? AppButton }).first
        else {
            return XCTFail("expected a segment AppButton")
        }
        let colorBefore = attributedTitleColor(firstSegment)
        XCTAssertNotNil(colorBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        control.reapplyTheme()

        XCTAssertNotEqual(colorBefore, attributedTitleColor(firstSegment))
    }

    func test_reapplyTheme_recolorsSettingsNavRow() throws {
        let row = SettingsNavRow(title: "General") {}
        row.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(row)
        row.frame = NSRect(x: 0, y: 0, width: 150, height: 30)

        guard let label = row.subviews.compactMap({ $0 as? NSTextField }).first else {
            return XCTFail("expected the row's label")
        }
        let colorBefore = label.textColor

        Theme.setCurrentForTesting(try makeAlternateTheme())
        row.reapplyTheme()

        XCTAssertNotEqual(colorBefore, label.textColor)
    }

    func test_reapplyTheme_recolorsSurfaceFloatOverlay() throws {
        let overlay = SurfaceFloatOverlay(
            content: NSView(), widthFraction: 0.6, heightFraction: 0.6, contentInset: 12,
            cornerRadius: 12, onDismiss: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 400, height: 300)

        guard overlay.subviews.count == 2 else {
            return XCTFail("expected backdrop + card subviews")
        }
        let card = overlay.subviews[1]
        let colorBefore = card.layer?.borderColor

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyTheme()

        XCTAssertNotEqual(colorBefore, card.layer?.borderColor)
    }

    func test_reapplyTheme_keepsTheAccentHaloOnSurfaceFloatOverlay() throws {
        let overlay = SurfaceFloatOverlay(
            content: NSView(), widthFraction: 0.6, heightFraction: 0.6, contentInset: 12,
            cornerRadius: 12, onDismiss: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 400, height: 300)

        guard overlay.subviews.count == 2 else {
            return XCTFail("expected backdrop + card subviews")
        }
        let card = overlay.subviews[1]

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyTheme()

        XCTAssertEqual(
            card.layer?.borderColor, Theme.current.chrome.accent.nsColor.cgColor,
            "the float's focus halo must survive a theme swap as the accent role")
        XCTAssertNotEqual(
            card.layer?.borderColor, FloatShadow.edge.cgColor,
            "a float that reverts to the neutral hairline no longer signals it holds focus")
    }

    private final class FakeSettingsSection: SettingsSection {
        var navTitle: String { "Fake" }
        var onExitToNav: (() -> Void)?
        var onClose: (() -> Void)?
        let resetButton = AppButton(title: "Reset all to defaults", variant: .muted)
        private(set) var sectionWillHideCallCount = 0
        private(set) var reapplyThemeCallCount = 0

        func makeDetailView() -> NSView { resetButton }
        func detailStops() -> [NSView] { [resetButton] }
        func sectionWillHide() { sectionWillHideCallCount += 1 }
        func reapplyTheme() {
            reapplyThemeCallCount += 1
            resetButton.reapplyTheme()
        }
    }

    func test_reapplyTheme_recolorsSettingsOverlayShellAndPersistentResetControl() throws {
        let section = FakeSettingsSection()
        let overlay = SettingsOverlay(
            sections: [section], capturer: nil,
            background: Theme.current.chrome.background.nsColor, onClose: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 620, height: 460)

        guard let card = overlay.subviews.compactMap({ $0 as? CardView }).first else {
            return XCTFail("expected the card")
        }
        let shellColorBefore = card.layer?.borderColor
        let resetColorBefore = attributedTitleColor(section.resetButton)
        XCTAssertNotNil(resetColorBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyTheme()

        XCTAssertNotEqual(shellColorBefore, card.layer?.borderColor)
        XCTAssertNotEqual(resetColorBefore, attributedTitleColor(section.resetButton))
    }

    func test_reapplyTheme_doesNotCallSectionWillHide() throws {
        let section = FakeSettingsSection()
        let overlay = SettingsOverlay(
            sections: [section], capturer: nil,
            background: Theme.current.chrome.background.nsColor, onClose: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 620, height: 460)

        let callsBefore = section.sectionWillHideCallCount

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyTheme()

        XCTAssertEqual(section.sectionWillHideCallCount, callsBefore)
    }

    func test_reapplyTheme_recolorsKeybindChipBox() throws {
        let row = KeybindRow(action: .newTab, title: "New Tab")
        row.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(row)
        row.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        row.render(currentShortcut: "⌘T")

        window.makeFirstResponder(row.chip)
        let borderBefore = row.chip.layer?.borderColor
        let fillBefore = row.chip.layer?.backgroundColor
        XCTAssertNotNil(borderBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        row.reapplyTheme()

        XCTAssertNotEqual(borderBefore, row.chip.layer?.borderColor)
        XCTAssertNotEqual(fillBefore, row.chip.layer?.backgroundColor)
    }

    func test_reapplyTheme_recolorsEveryHiddenSectionToo() throws {
        let visible = FakeSettingsSection()
        let hidden = FakeSettingsSection()
        let overlay = SettingsOverlay(
            sections: [visible, hidden], capturer: nil,
            background: Theme.current.chrome.background.nsColor, onClose: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 620, height: 460)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyTheme()

        XCTAssertEqual(hidden.reapplyThemeCallCount, 1)
        XCTAssertEqual(hidden.sectionWillHideCallCount, 0)
    }
}
