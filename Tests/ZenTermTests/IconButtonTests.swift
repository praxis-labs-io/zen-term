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
    /// subtitles beside it. It sat at 0.55, the same as `ink(alpha: 0.5)` secondary text, which is
    /// the kind of drift no assertion catches and no glance reliably does either: both look "grey".
    @MainActor
    func test_theRestingIcon_readsStrongerThanSecondaryText() {
        let button = IconButton(symbol: "plus", accessibilityLabel: "New tab", onClick: {})
        guard let tint = button.iconTintForTesting?.usingColorSpace(.sRGB) else {
            return XCTFail("no tint painted on the glyph")
        }
        let secondary = Theme.current.chrome.ink(alpha: 0.5).usingColorSpace(.sRGB)
        XCTAssertGreaterThan(
            tint.alphaComponent, secondary?.alphaComponent ?? 1,
            "the resting icon is at or below secondary-text weight")
    }

    /// And below the hover tint, or the hover shift stops reading. `inkBoost` clamps past ~0.77, so
    /// raising the resting value too far silently collapses the two into one.
    @MainActor
    func test_theRestingIcon_staysBelowTheHoverTint() {
        let resting = Theme.current.chrome.ink(alpha: ChromeTheme.restingControlAlpha)
        let hover = Theme.current.chrome.ink(alpha: 0.95)
        XCTAssertLessThan(resting.alphaComponent, hover.alphaComponent)
    }
}
