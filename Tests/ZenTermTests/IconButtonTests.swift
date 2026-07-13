import AppKit
import XCTest

@testable import ZenTerm

/// The shared icon button gained a hover tooltip (ZEN-42) and a busy activity dot (ZEN-107).
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
}
