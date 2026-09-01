import AppKit
import XCTest

@testable import ZenTerm

/// The shared icon button gained a hover tooltip and a busy activity dot.
final class IconButtonTests: XCTestCase {
    func test_tooltip_labelAndLiveShortcut() {
        // The shortcut resolves at hover time (via the closure), so it can track the live keymap
        // instead of freezing a literal.
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

    // MARK: - resting weight

    /// A toolbar icon is the thing you click, so it must not read at the weight of the hints and
    /// subtitles beside it. It shared their weight exactly, which is
    /// the kind of drift no assertion catches and no glance reliably does either: both look "grey".
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

    /// And below the hover weight, or the hover shift stops reading at all.
    @MainActor
    func test_theRestingIcon_staysBelowTheHoverTint() {
        XCTAssertLessThan(
            Theme.current.chrome.ink(.subtle).alphaComponent,
            Theme.current.chrome.ink(.normal).alphaComponent)
    }
}

/// The brand marks and the SF Symbols have to draw at the same size in a row together. That is a
/// budget the eye can't police to a point: the `pointSize + 2` this replaced looked plausible for
/// years while drawing logos 10% taller than the symbols beside them. So measure the ink.
final class IconGlyphSizeTests: XCTestCase {
    /// Ink bounding-box height of an image, supersampled so a 13pt glyph measures to a fraction.
    /// Where the glyph's image box actually sits inside a laid-out button, in exact layout
    /// coordinates. Pixels can't resolve this: a quarter point is half a pixel at 2x, and the ink
    /// bounding box won't budge for it.
    private func glyphCentreOffset(_ symbol: String) throws -> CGFloat {
        let button = IconButton(symbol: symbol, pointSize: 12, accessibilityLabel: symbol) {}
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        button.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(
            button.subviews.compactMap { $0 as? NSImageView }.first, "no glyph view in \(symbol)")
        return image.frame.midY - button.bounds.midY
    }

    /// An SF Symbol's alignment rect is baseline-derived and sits off-centre in the image, so Auto
    /// Layout hangs it high beside a brand mark whose rect is its whole bounds. A quarter point is
    /// invisible one glyph at a time and obvious in a row of eight.
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
