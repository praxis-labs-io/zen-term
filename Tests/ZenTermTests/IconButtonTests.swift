import AppKit
import XCTest

@testable import ZenTerm

/// The shared icon button gained a hover tooltip (ZEN-42) and a busy activity dot (ZEN-107).
final class IconButtonTests: XCTestCase {
    func test_toolTip_combinesLabelAndShortcut() {
        let withShortcut = IconButton(
            symbol: "plus", accessibilityLabel: "New tab", shortcut: "⌘T", onClick: {})
        XCTAssertEqual(withShortcut.toolTip, "New tab  ⌘T")

        let plain = IconButton(symbol: "plus", accessibilityLabel: "New tab", onClick: {})
        XCTAssertEqual(plain.toolTip, "New tab", "no shortcut → tooltip is just the label")
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
