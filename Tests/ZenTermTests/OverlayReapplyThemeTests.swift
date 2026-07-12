import AppKit
import XCTest

@testable import ZenTerm

/// Window-mounted recolor tests for the palette overlays + Add-Workspace form's
/// `reapplyTheme()` (ZEN-89 task 8). Same pattern as `ReapplyThemeTests` (Task 6/7): swap
/// `Theme.current` via `Theme.setCurrentForTesting(_:)`, call `reapplyTheme()`, assert a real
/// color-bearing property changed. These overlays additionally hold IN-PROGRESS user input
/// (a typed search query, a typed field value, a typed env var) that a naive rebuild would
/// lose — the state-preservation assertions (the typed value is unchanged after the recolor)
/// are the point of this file, not just the color change.
///
/// Every property under test here is `private` on its owning overlay, so tests reach it the
/// same way `ReapplyThemeTests` reaches `SettingsOverlay`'s card/button: walk the live subview
/// tree (a runtime, not compile-time, operation — Swift's `private` doesn't hide it).
final class OverlayReapplyThemeTests: XCTestCase {
    private var originalTheme: AppTheme!
    private var tempRoots: [URL] = []

    override func setUp() {
        super.setUp()
        originalTheme = Theme.current
    }

    override func tearDownWithError() throws {
        Theme.setCurrentForTesting(originalTheme)
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
        try super.tearDownWithError()
    }

    /// A theme whose background/foreground/accent/destructive are all clearly distinct from
    /// Rosé Pine Moon's — same construction `ReapplyThemeTests` uses, kept independent here so
    /// this file has no cross-file test dependency.
    private func makeAlternateTheme() throws -> AppTheme {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-overlay-reapply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempRoots.append(dir)
        try """
        background = #010101
        foreground = #fefefe
        palette = 1=#ff0000
        palette = 5=#00ff00
        """.write(to: dir.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        return ConfigLoader.loadAppTheme(configRoot: dir, general: .builtIn)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
    }

    /// Every subview beneath `view`, recursively — walks the live AppKit tree regardless of the
    /// Swift access level of the property that stored it.
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    // MARK: PaletteOverlay (RepoPickerOverlay)

    func test_reapplyTheme_recolorsPaletteOverlayAndPreservesSearchQuery() throws {
        let overlay = RepoPickerOverlay(
            entries: [], background: Theme.current.chrome.background.nsColor,
            onChoose: { _, _ in }, onAddWorkspace: {}, onDismiss: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 560, height: 400)

        guard
            let searchField = descendants(of: overlay).compactMap({ $0 as? NSTextField })
                .first(where: { $0.isEditable })
        else {
            return XCTFail("expected the search field")
        }
        searchField.stringValue = "swap"

        let colorBefore = searchField.textColor
        XCTAssertNotNil(colorBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyTheme()

        XCTAssertNotEqual(colorBefore, searchField.textColor)
        // The typed query lives in `searchField`, untouched by the row re-render — it must survive.
        XCTAssertEqual(searchField.stringValue, "swap")
    }

    func test_reapplyTheme_recolorsPaletteOverlayCardShell() throws {
        let overlay = CommandPaletteOverlay(
            commands: [], background: Theme.current.chrome.background.nsColor,
            onRun: { _ in }, onDismiss: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 560, height: 400)

        guard let card = overlay.subviews.compactMap({ $0 as? CardView }).first else {
            return XCTFail("expected the card")
        }
        let colorBefore = card.layer?.borderColor

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyTheme()

        XCTAssertNotEqual(colorBefore, card.layer?.borderColor)
    }

    // MARK: AddWorkspaceOverlay

    func test_reapplyTheme_recolorsAddWorkspaceOverlayAndPreservesTypedTitle() throws {
        let overlay = AddWorkspaceOverlay(
            existingTitles: [], background: Theme.current.chrome.background.nsColor,
            onSubmit: { _ in }, onCancel: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 460, height: 640)

        guard
            let header = descendants(of: overlay).compactMap({ $0 as? NSTextField })
                .first(where: { $0.stringValue == "New Workspace" })
        else {
            return XCTFail("expected the header label")
        }
        guard
            let titleField = descendants(of: overlay).compactMap({ $0 as? FieldBox })
                .first(where: { $0.field.placeholderString == "Workspace name" })
        else {
            return XCTFail("expected the title field")
        }
        titleField.setText("my-project")

        let headerColorBefore = header.textColor
        let titleColorBefore = titleField.field.textColor
        XCTAssertNotNil(headerColorBefore)
        XCTAssertNotNil(titleColorBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyTheme()

        XCTAssertNotEqual(headerColorBefore, header.textColor)
        XCTAssertNotEqual(titleColorBefore, titleField.field.textColor)
        // The typed title lives in `titleField`, untouched by the in-place recolor.
        XCTAssertEqual(titleField.text, "my-project")
    }

    func test_reapplyTheme_recolorsAddWorkspaceCardShell() throws {
        let overlay = AddWorkspaceOverlay(
            existingTitles: [], background: Theme.current.chrome.background.nsColor,
            onSubmit: { _ in }, onCancel: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 460, height: 640)

        guard let card = overlay.subviews.compactMap({ $0 as? CardView }).first else {
            return XCTFail("expected the card")
        }
        let colorBefore = card.layer?.borderColor

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyTheme()

        XCTAssertNotEqual(colorBefore, card.layer?.borderColor)
    }

    func test_reapplyTheme_recolorsEnvRowAndPreservesTypedKey() throws {
        let overlay = AddWorkspaceOverlay(
            existingTitles: [], background: Theme.current.chrome.background.nsColor,
            onSubmit: { _ in }, onCancel: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 460, height: 640)

        guard
            let addVarButton = descendants(of: overlay).compactMap({ $0 as? AppButton })
                .first(where: { $0.attributedTitle.string == "＋ Add variable" })
        else {
            return XCTFail("expected the add-variable button")
        }
        addVarButton.onTap()  // adds one dynamic EnvRow

        guard
            let keyBox = descendants(of: overlay).compactMap({ $0 as? FieldBox })
                .first(where: { $0.field.placeholderString == "KEY" })
        else {
            return XCTFail("expected the env row's KEY field")
        }
        keyBox.setText("FOO")

        guard
            let equalsLabel = descendants(of: overlay).compactMap({ $0 as? NSTextField })
                .first(where: { $0.stringValue == "=" })
        else {
            return XCTFail("expected the env row's = label")
        }

        let keyColorBefore = keyBox.field.textColor
        let equalsColorBefore = equalsLabel.textColor
        XCTAssertNotNil(keyColorBefore)
        XCTAssertNotNil(equalsColorBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyTheme()

        XCTAssertNotEqual(keyColorBefore, keyBox.field.textColor)
        // The `=` label is otherwise-stranded static chrome — it must recolor too, not just the boxes.
        XCTAssertNotEqual(equalsColorBefore, equalsLabel.textColor)
        // The typed env key survives — this row is never rebuilt, only recolored in place.
        XCTAssertEqual(keyBox.text, "FOO")
    }

    func test_reapplyTheme_recolorsFieldGroupCaption() throws {
        let overlay = AddWorkspaceOverlay(
            existingTitles: [], background: Theme.current.chrome.background.nsColor,
            onSubmit: { _ in }, onCancel: {})
        overlay.translatesAutoresizingMaskIntoConstraints = true
        let window = makeWindow()
        window.contentView?.addSubview(overlay)
        overlay.frame = NSRect(x: 0, y: 0, width: 460, height: 640)

        guard
            let caption = descendants(of: overlay).compactMap({ $0 as? NSTextField })
                .first(where: { $0.attributedStringValue.string == "WORKSPACE NAME ✳" })
        else {
            return XCTFail("expected the WORKSPACE NAME caption")
        }
        let colorBefore =
            caption.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil)
            as? NSColor
        XCTAssertNotNil(colorBefore)

        Theme.setCurrentForTesting(try makeAlternateTheme())
        overlay.reapplyTheme()

        let colorAfter =
            caption.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil)
            as? NSColor
        XCTAssertNotEqual(colorBefore, colorAfter)
    }
}
