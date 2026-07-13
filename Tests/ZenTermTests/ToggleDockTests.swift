import AppKit
import XCTest

@testable import ZenTerm

/// Guards the dock's live rebuild (ZEN-109): a float added / edited / removed in Settings must
/// change the toolbar's per-float buttons, not just recolor them. The bug shipped because the
/// config-change fan-out only re-themed the dock; the button set was built once and never rebuilt.
final class ToggleDockTests: XCTestCase {
    private func float(_ id: String) -> ToolFloat {
        ToolFloat(
            id: id, title: "Open \(id)", icon: "square.on.square", command: "cmd",
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false, emptyGuard: nil,
            toggle: Chord(command: true, shift: true, key: "d"))
    }

    private func makeDock(_ floats: [ToolFloat]) -> ToggleDock {
        ToggleDock(
            onSplitH: {}, onSplitV: {}, onPalette: {}, onBottom: {}, onRight: {}, onZoom: {},
            onLazygit: {}, toolFloats: floats, onToolFloat: { _ in })
    }

    func test_setToolFloats_rebuildsButtonsForCatalog() {
        let dock = makeDock([float("dev")])
        XCTAssertEqual(dock.toolFloatButtonIDsForTesting, ["dev"])

        dock.setToolFloats([float("dev"), float("top")])  // add
        XCTAssertEqual(dock.toolFloatButtonIDsForTesting, ["dev", "top"])

        dock.setToolFloats([float("top")])  // remove one
        XCTAssertEqual(dock.toolFloatButtonIDsForTesting, ["top"])

        dock.setToolFloats([])  // remove all
        XCTAssertTrue(dock.toolFloatButtonIDsForTesting.isEmpty)
    }
}
