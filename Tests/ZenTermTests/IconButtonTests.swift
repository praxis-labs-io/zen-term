import AppKit
import XCTest

@testable import ZenTerm

final class IconButtonTests: XCTestCase {
    func test_tooltip_labelAndLiveShortcut() {
        let withShortcut = IconButton(
            symbol: "plus", accessibilityLabel: "New tab", shortcut: { "⌘T" }, onClick: {})
        XCTAssertEqual(withShortcut.tooltipLabelForTesting, "New tab")
        XCTAssertEqual(withShortcut.tooltipShortcutForTesting, "⌘T")

        let plain = IconButton(symbol: "plus", accessibilityLabel: "New tab", onClick: {})
        XCTAssertEqual(plain.tooltipLabelForTesting, "New tab")
        XCTAssertNil(plain.tooltipShortcutForTesting, "no resolver → no shortcut in the tooltip")
    }

    func test_showsActivity_togglesTheDot() {
        let button = IconButton(
            symbol: "rectangle.bottomthird.inset.filled", accessibilityLabel: "Toggle bottom drawer",
            onClick: {})
        XCTAssertTrue(button.activityDotHiddenForTesting, "dot is hidden by default")

        button.showsActivity = true
        XCTAssertFalse(button.activityDotHiddenForTesting, "showsActivity reveals the dot")

        button.showsActivity = false
        XCTAssertTrue(button.activityDotHiddenForTesting)
    }

    @MainActor
    func test_theRestingIcon_readsStrongerThanSecondaryText() {
        let button = IconButton(symbol: "plus", accessibilityLabel: "New tab", onClick: {})
        guard let tint = button.iconTintForTesting?.usingColorSpace(.sRGB) else {
            return XCTFail("no tint painted on the glyph")
        }
        let secondary = Theme.current.chrome.ink(.muted).usingColorSpace(.sRGB)
        XCTAssertGreaterThan(
            tint.alphaComponent, secondary?.alphaComponent ?? 1,
            "the resting icon is at or below secondary-text weight")
    }

    @MainActor
    func test_theRestingIcon_staysBelowTheHoverTint() {
        XCTAssertLessThan(
            Theme.current.chrome.ink(.subtle).alphaComponent,
            Theme.current.chrome.ink(.normal).alphaComponent)
    }
}

final class IconGlyphSizeTests: XCTestCase {
    private func glyphCentreOffset(_ symbol: String) throws -> CGFloat {
        let button = IconButton(symbol: symbol, pointSize: 12, accessibilityLabel: symbol) {}
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        button.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(
            button.subviews.compactMap { $0 as? NSImageView }.first, "no glyph view in \(symbol)")
        return image.frame.midY - button.bounds.midY
    }

    func test_symbolsAndBrandMarks_shareAVerticalCentre() throws {
        let symbols = try ["terminal.fill", "folder.fill", "doc.text.fill", "square.stack.fill"]
            .map(glyphCentreOffset)
        let brands = try ["git", "github", "claude"].map(glyphCentreOffset)
        let symbolMean = symbols.reduce(0, +) / CGFloat(symbols.count)
        let brandMean = brands.reduce(0, +) / CGFloat(brands.count)

        XCTAssertEqual(
            symbolMean, brandMean, accuracy: 0.05,
            "symbols centre at \(symbolMean), marks at \(brandMean) — the row sits unevenly")
        let spread = (symbols.max() ?? 0) - (symbols.min() ?? 0)
        XCTAssertLessThan(spread, 0.05, "the roster disagrees with itself by \(spread)pt")
    }

}
