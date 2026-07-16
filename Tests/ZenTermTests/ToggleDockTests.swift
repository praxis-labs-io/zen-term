import AppKit
import XCTest

@testable import ZenTerm

/// Guards the dock's live rebuild (ZEN-109): a float added / edited / removed in Settings must
/// change the toolbar's per-float buttons, not just recolor them. The bug shipped because the
/// config-change fan-out only re-themed the dock; the button set was built once and never rebuilt.
final class ToggleDockTests: XCTestCase {
    private func float(_ id: String) -> ToolFloat {
        ToolFloat(
            id: id, title: "Open \(id)", icon: "square.on.square", command: "cmd", dir: nil,
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
            persist: .ephemeral, toggle: Chord(command: true, shift: true, key: "d"))
    }

    private func makeDock(_ floats: [ToolFloat]) -> ToggleDock {
        ToggleDock(
            onNewTab: {}, onSplitH: {}, onSplitV: {}, onPalette: {}, onBottom: {}, onRight: {},
            onZoom: {}, toolFloats: floats, onToolFloat: { _ in })
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

    func test_render_showsActivityDotForBusyDrawer() {
        let dock = makeDock([])

        var overlay = OverlayState()
        overlay.bottomBusy = true
        dock.render(overlay: overlay, floatID: nil, paletteOpen: false)
        XCTAssertTrue(dock.bottomActivityForTesting, "a busy bottom drawer must dot its toggle")
        XCTAssertFalse(dock.rightActivityForTesting)

        overlay.bottomBusy = false
        overlay.rightBusy = true
        dock.render(overlay: overlay, floatID: nil, paletteOpen: false)
        XCTAssertFalse(dock.bottomActivityForTesting)
        XCTAssertTrue(dock.rightActivityForTesting)
    }

    func test_render_dotShowsEvenWhileDrawerOpen() {
        // The dot signals a live process regardless of whether the drawer is currently shown.
        let dock = makeDock([])
        var overlay = OverlayState()
        overlay.isBottomOpen = true
        overlay.bottomBusy = true
        dock.render(overlay: overlay, floatID: nil, paletteOpen: false)
        XCTAssertTrue(dock.bottomActivityForTesting)
    }

    func test_render_noDotWhenIdle() {
        let dock = makeDock([])
        dock.render(overlay: OverlayState(), floatID: nil, paletteOpen: false)
        XCTAssertFalse(dock.bottomActivityForTesting)
        XCTAssertFalse(dock.rightActivityForTesting)
    }

    // MARK: live-in-background float dots (ZEN-150)

    func test_render_dotsFloatsLiveInBackground_notTheShownOne() {
        let dock = makeDock([float("dev"), float("top")])

        // "dev" is shown, "top" is alive behind the scenes — only the hidden one earns a dot.
        dock.render(
            overlay: OverlayState(), floatID: "dev", paletteOpen: false,
            isLiveInBackground: { $0 == "top" })

        XCTAssertEqual(dock.dottedToolFloatIDsForTesting, ["top"])
    }

    func test_render_noLiveFloats_noDots() {
        let dock = makeDock([float("dev")])
        dock.render(overlay: OverlayState(), floatID: nil, paletteOpen: false)
        XCTAssertTrue(dock.dottedToolFloatIDsForTesting.isEmpty)
    }

    /// The dot must clear when the tool dies, not just when a card opens — a dot outliving its
    /// process is the ZEN-150 stale-dot bug.
    func test_render_dotClearsWhenTheFloatIsNoLongerLive() {
        let dock = makeDock([float("top")])
        dock.render(
            overlay: OverlayState(), floatID: nil, paletteOpen: false, isLiveInBackground: { _ in true })
        XCTAssertEqual(dock.dottedToolFloatIDsForTesting, ["top"])

        dock.render(
            overlay: OverlayState(), floatID: nil, paletteOpen: false, isLiveInBackground: { _ in false })

        XCTAssertTrue(dock.dottedToolFloatIDsForTesting.isEmpty, "a re-render after exit clears the dot")
    }

    func test_newTabButton_isMounted() {
        // New-tab moved from the tab strip into the dock (ZEN-115); it must always be present so it
        // never scrolls away with the tabs.
        XCTAssertTrue(makeDock([]).hasNewTabButtonForTesting)
    }
}
