import AppKit
import XCTest

@testable import ZenTerm

/// Guards the dock's live rebuild (ZEN-109): a float added / edited / removed in Settings must
/// change the toolbar's per-float buttons, not just recolor them. The bug shipped because the
/// config-change fan-out only re-themed the dock; the button set was built once and never rebuilt.
final class ToggleDockTests: XCTestCase {
    /// `title` doubles as the id — a real float's id is always `slug(title)`, and a factory that let
    /// the two diverge would be building a float the config could never produce.
    private func float(_ id: String, order: Int = 0) -> ToolFloat {
        ToolFloat(
            id: id, order: order, title: id, icon: "square.on.square", command: "cmd", dir: nil,
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
            persist: .ephemeral, toggle: Chord(command: true, shift: true, key: "d"))
    }

    private func makeDock(_ floats: [ToolFloat]) -> ToggleDock {
        ToggleDock(
            onNewTab: {}, onSplitH: {}, onSplitV: {}, onPalette: {}, onBottom: {}, onRight: {},
            onZoom: {}, onDiffViewer: {}, toolFloats: floats, onToolFloat: { _ in })
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

    /// The dock renders the catalog in array order, left to right — it does no sorting of its own, so
    /// a reorder in Settings reaches the toolbar only if this holds (ZEN-145).
    func test_setToolFloats_rendersButtonsInCatalogOrder() {
        let dock = makeDock([float("dev", order: 1), float("top", order: 2), float("notes", order: 3)])
        XCTAssertEqual(dock.toolFloatButtonIDsForTesting, ["dev", "top", "notes"])

        dock.setToolFloats([float("notes", order: 1), float("dev", order: 2), float("top", order: 3)])
        XCTAssertEqual(dock.toolFloatButtonIDsForTesting, ["notes", "dev", "top"])
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

    // MARK: hidden buttons + divider grouping (ZEN-327)

    private static let fixedDefault = [
        "New tab", "│",
        "Split horizontally", "Split vertically", "Toggle bottom drawer", "Toggle right drawer",
        "Focus mode", "│",
        "Command palette", "Diff viewer",
    ]

    func test_defaultLayout_groupsWithTwoDividers_noTrailingDivider() {
        // No floats: the third divider must not dangle at the tail.
        XCTAssertEqual(makeDock([]).visibleLayoutForTesting, Self.fixedDefault)
    }

    func test_floats_getTheirOwnDividerSeparatedGroup() {
        XCTAssertEqual(
            makeDock([float("dev")]).visibleLayoutForTesting,
            Self.fixedDefault + ["│", "dev"])
    }

    func test_setHiddenButtons_hidesAndRestores() {
        let dock = makeDock([])
        dock.setHiddenButtons([.diffViewer, .splitVertical])
        XCTAssertEqual(
            dock.visibleLayoutForTesting,
            [
                "New tab", "│",
                "Split horizontally", "Toggle bottom drawer", "Toggle right drawer", "Focus mode",
                "│", "Command palette",
            ])

        dock.setHiddenButtons([])
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)
    }

    func test_emptyMiddleGroup_collapsesToOneDivider() {
        let dock = makeDock([])
        dock.setHiddenButtons([.splitHorizontal, .splitVertical, .bottomDrawer, .rightDrawer, .focusMode])
        XCTAssertEqual(
            dock.visibleLayoutForTesting, ["New tab", "│", "Command palette", "Diff viewer"])
    }

    func test_hiddenFirstGroup_leavesNoLeadingDivider() {
        let dock = makeDock([])
        dock.setHiddenButtons([.newTab])
        XCTAssertEqual(
            dock.visibleLayoutForTesting,
            [
                "Split horizontally", "Split vertically", "Toggle bottom drawer",
                "Toggle right drawer", "Focus mode", "│", "Command palette", "Diff viewer",
            ])
    }

    func test_everyFixedButtonHidden_showsNothing_andFloatsStandAlone() {
        let dock = makeDock([])
        dock.setHiddenButtons(Set(ToolbarButton.allCases))
        XCTAssertTrue(dock.visibleLayoutForTesting.isEmpty)

        // A float alone gets no divider — there is nothing visible to its left.
        dock.setToolFloats([float("dev")])
        XCTAssertEqual(dock.visibleLayoutForTesting, ["dev"])
    }

    func test_hiddenNewTab_reportsNotMounted() {
        // Guards the arrangedSubviews trap: a hidden arranged subview stays in the array, so the
        // hook must read `isHidden`, not mere membership.
        let dock = makeDock([])
        dock.setHiddenButtons([.newTab])
        XCTAssertFalse(dock.hasNewTabButtonForTesting)
    }

    func test_floatWithToolbarFalse_getsNoVisibleButton_andNoFloatDivider() {
        var hidden = float("dev")
        hidden.showsInToolbar = false
        let dock = makeDock([hidden, float("top")])
        XCTAssertEqual(dock.toolFloatButtonIDsForTesting, ["top"])

        dock.setToolFloats([hidden])
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)

        // A render with the tool idle keeps it hidden — surfacing is for running tools only.
        dock.render(overlay: OverlayState(), floatID: nil, paletteOpen: false)
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)
    }

    /// The liveness handle: a `toolbar:false` float's button must surface (dot and all) while its
    /// tool runs in the background, and hide again when it dies — otherwise a hidden persistent
    /// float is a running process with no visible trace anywhere (the ZEN-150 dot is its only one).
    func test_hiddenFloat_surfacesWhileLiveInBackground_andRehidesWhenItDies() {
        var hidden = float("dev")
        hidden.showsInToolbar = false
        let dock = makeDock([hidden])
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)

        dock.render(
            overlay: OverlayState(), floatID: nil, paletteOpen: false,
            isLiveInBackground: { $0 == "dev" })
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault + ["│", "dev"])
        XCTAssertEqual(dock.dottedToolFloatIDsForTesting, ["dev"])

        dock.render(overlay: OverlayState(), floatID: nil, paletteOpen: false)
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault, "the handle leaves with the process")
    }

    func test_hiddenFloat_surfacesWhileItsCardIsShown() {
        var hidden = float("dev")
        hidden.showsInToolbar = false
        let dock = makeDock([hidden])

        dock.render(overlay: OverlayState(), floatID: "dev", paletteOpen: false)
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault + ["│", "dev"])
    }

    /// The stack order and recolor list derive from `ToolbarButton.groups` / `allCases`, so a case
    /// missing from `groups` would silently never mount. Order-sensitive on purpose: the groups
    /// flattened ARE the toolbar order.
    func test_toolbarButtonGroups_coverEveryCaseInOrder() {
        XCTAssertEqual(ToolbarButton.groups.flatMap { $0 }, ToolbarButton.allCases)
    }
}
