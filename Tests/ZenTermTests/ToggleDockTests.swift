import AppKit
import XCTest

@testable import ZenTerm

/// Guards the dock's live rebuild: a float added / edited / removed in Settings must
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

    /// The dock renders the catalog in array order, left to right — it does no sorting of its own, so
    /// a reorder in Settings reaches the toolbar only if this holds.
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

    // MARK: live-in-background float dots

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
    /// process is the stale-dot bug.
    func test_render_dotClearsWhenTheFloatIsNoLongerLive() {
        let dock = makeDock([float("top")])
        dock.render(
            overlay: OverlayState(), floatID: nil, paletteOpen: false, isLiveInBackground: { _ in true })
        XCTAssertEqual(dock.dottedToolFloatIDsForTesting, ["top"])

        dock.render(
            overlay: OverlayState(), floatID: nil, paletteOpen: false, isLiveInBackground: { _ in false })

        XCTAssertTrue(dock.dottedToolFloatIDsForTesting.isEmpty, "a re-render after exit clears the dot")
    }

    // MARK: the built-in Scratch button

    /// Press the real button rather than calling the closure: `accessibilityPerformPress` is the
    /// same path `mouseDown` takes, so a button wired to nothing fails here.
    private func press(_ label: String, in dock: ToggleDock) {
        let button = descendants(of: dock).compactMap { $0 as? IconButton }
            .first { $0.accessibilityLabel() == label }
        XCTAssertNotNil(button, "no button labelled \(label)")
        _ = button?.accessibilityPerformPress()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    func test_scratchButton_togglesTheBuiltInFloat() {
        var toggled: [String] = []
        let dock = ToggleDock(
            onNewTab: {}, onSplitH: {}, onSplitV: {}, onPalette: {}, onBottom: {}, onRight: {},
            onZoom: {}, toolFloats: [], onToolFloat: { toggled.append($0.id) })

        press("Scratch", in: dock)

        XCTAssertEqual(toggled, ["scratch"])
    }

    /// The Scratch button is the card, so it must stay lit while its own float is open — the
    /// dimming that hides the drawer and zoom pips behind a card must not reach it.
    func test_render_scratchButtonStaysLitWhileItsOwnCardIsUp() {
        let dock = makeDock([])
        var overlay = OverlayState()
        overlay.isBottomOpen = true

        dock.render(overlay: overlay, floatID: "scratch", paletteOpen: false)

        XCTAssertTrue(dock.scratchActiveForTesting, "the button IS the card, so it must stay lit")
        XCTAssertFalse(dock.scratchActivityForTesting, "shown, so no background dot")
    }

    /// The other side of the same rule: a DIFFERENT float's card dims the drawer pips, and must
    /// leave Scratch dark rather than lit.
    func test_render_scratchButtonIsDarkWhileAnotherFloatsCardIsUp() {
        let dock = makeDock([float("dev")])

        dock.render(overlay: OverlayState(), floatID: "dev", paletteOpen: false)

        XCTAssertFalse(dock.scratchActiveForTesting)
    }

    /// Its dot lives on the fixed button, which `dottedToolFloatIDsForTesting` never walks — that
    /// hook only covers the config-driven tail.
    func test_render_dotsScratchWhileItRunsHidden() {
        let dock = makeDock([])

        dock.render(
            overlay: OverlayState(), floatID: nil, paletteOpen: false,
            isLiveInBackground: { $0 == "scratch" })
        XCTAssertTrue(dock.scratchActivityForTesting)

        dock.render(overlay: OverlayState(), floatID: nil, paletteOpen: false)
        XCTAssertFalse(dock.scratchActivityForTesting, "a re-render after exit clears the dot")
    }

    func test_newTabButton_isMounted() {
        // New-tab moved from the tab strip into the dock; it must always be present so it
        // never scrolls away with the tabs.
        XCTAssertTrue(makeDock([]).hasNewTabButtonForTesting)
    }

    // MARK: hidden buttons + divider grouping

    private static let fixedDefault = [
        "New tab", "│",
        "Split horizontally", "Split vertically", "Toggle bottom drawer", "Toggle right drawer",
        "Scratch", "Focus mode", "│",
        "Command palette",
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
        dock.setHiddenButtons([.scratch, .splitVertical])
        XCTAssertEqual(
            dock.visibleLayoutForTesting,
            [
                "New tab", "│",
                "Split horizontally", "Toggle bottom drawer", "Toggle right drawer",
                "Focus mode", "│", "Command palette",
            ])

        dock.setHiddenButtons([])
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)
    }

    func test_emptyMiddleGroup_collapsesToOneDivider() {
        let dock = makeDock([])
        dock.setHiddenButtons([
            .splitHorizontal, .splitVertical, .bottomDrawer, .rightDrawer, .scratch, .focusMode,
        ])
        XCTAssertEqual(
            dock.visibleLayoutForTesting, ["New tab", "│", "Command palette"])
    }

    func test_hiddenFirstGroup_leavesNoLeadingDivider() {
        let dock = makeDock([])
        dock.setHiddenButtons([.newTab])
        XCTAssertEqual(
            dock.visibleLayoutForTesting,
            [
                "Split horizontally", "Split vertically", "Toggle bottom drawer",
                "Toggle right drawer", "Scratch", "Focus mode", "│", "Command palette",
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
    /// float is a running process with no visible trace anywhere (the dot is its only one).
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

    // MARK: hidden drawers and Scratch surface while they work

    private static let bottomHidden = fixedDefault.filter { $0 != "Toggle bottom drawer" }
    private static let scratchHidden = fixedDefault.filter { $0 != "Scratch" }

    private func render(
        _ dock: ToggleDock, _ overlay: OverlayState = OverlayState(), floatID: String? = nil,
        scratchBusy: Bool = false, scratchLive: Bool = false
    ) {
        dock.render(
            overlay: overlay, floatID: floatID, paletteOpen: false,
            isLiveInBackground: { scratchLive && $0 == ToolFloat.scratch.id },
            isFloatBusy: { scratchBusy && $0 == ToolFloat.scratch.id })
    }

    /// A hidden drawer running something has no other trace on screen, so the button comes back
    /// with its dot and leaves again when the work ends.
    func test_hiddenDrawer_surfacesWhileBusy_andRehidesWhenIdle() {
        let dock = makeDock([])
        dock.setHiddenButtons([.bottomDrawer])
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.bottomHidden)

        render(dock, OverlayState(bottomBusy: true))
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)
        XCTAssertTrue(dock.bottomActivityForTesting)

        render(dock)
        XCTAssertEqual(
            dock.visibleLayoutForTesting, Self.bottomHidden, "the handle leaves with the process")
    }

    /// Open is not a reason: the drawer is already on screen, so the button would add nothing.
    func test_hiddenDrawer_staysHiddenWhileIdleAndOpen() {
        let dock = makeDock([])
        dock.setHiddenButtons([.bottomDrawer])

        render(dock, OverlayState(isBottomOpen: true))
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.bottomHidden)
    }

    /// The spawn flash: a shell reads busy until its first prompt mark, and a drawer only ever
    /// spawns one while it is on screen. Busy alone would pop the button in and out on every open.
    func test_hiddenDrawer_staysHiddenWhileBusyAndOnScreen() {
        let dock = makeDock([])
        dock.setHiddenButtons([.bottomDrawer])

        render(dock, OverlayState(isBottomOpen: true, bottomBusy: true))
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.bottomHidden)
    }

    /// Focus mode on a pane takes an open drawer off screen, so a busy one is out of sight again
    /// and earns its handle back.
    func test_hiddenDrawer_surfacesWhileBusyAndZoomedAway() {
        let dock = makeDock([])
        dock.setHiddenButtons([.bottomDrawer])

        render(dock, OverlayState(isBottomOpen: true, zoomed: .pane, bottomBusy: true))
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)
    }

    /// A tab that never opened a drawer reaches the dock as this same idle state, so one input
    /// covers both: nothing has ever run, and nothing is running now.
    func test_hiddenDrawer_staysHiddenWhileIdleAndClosed() {
        let dock = makeDock([])
        dock.setHiddenButtons([.rightDrawer])

        render(dock)
        XCTAssertEqual(
            dock.visibleLayoutForTesting, Self.fixedDefault.filter { $0 != "Toggle right drawer" })
    }

    /// Surfacing is only ever a hidden button's business: a shown one is already there, busy or not.
    func test_shownDrawer_isUnaffectedByBusy() {
        let dock = makeDock([])

        render(dock, OverlayState(bottomBusy: true, rightBusy: true))
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)
    }

    /// Hiding a drawer that is mid-job (a live Settings edit) leaves it on screen, rather than
    /// dropping the handle on work already running.
    func test_hidingABusyDrawer_leavesItOnScreen() {
        let dock = makeDock([])
        render(dock, OverlayState(bottomBusy: true))

        dock.setHiddenButtons([.bottomDrawer])
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)
    }

    /// Scratch keys off busy, not the liveness every other float uses: its shell stays live for the
    /// tab's life once opened, so liveness would put a hidden button back for good after one ⌘;.
    func test_hiddenScratch_surfacesWhileBusy_notMerelyLive() {
        let dock = makeDock([])
        dock.setHiddenButtons([.scratch])

        render(dock, scratchLive: true)
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.scratchHidden)

        render(dock, scratchBusy: true, scratchLive: true)
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)
        XCTAssertTrue(dock.scratchActivityForTesting)
    }

    /// The reported flash: opening Scratch spawns a shell that reads busy until its first prompt
    /// mark, and the card is up the whole time, so the button must not appear and then drop.
    func test_hiddenScratch_staysHiddenWhileItsOwnCardIsUp() {
        let dock = makeDock([])
        dock.setHiddenButtons([.scratch])

        render(dock, floatID: ToolFloat.scratch.id, scratchBusy: true)
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.scratchHidden)
    }

    /// A surfaced button counts for the divider grouping too, or the middle group comes back with
    /// no divider between it and the palette.
    func test_surfacedDrawer_bringsBackItsGroupDivider() {
        let dock = makeDock([])
        dock.setHiddenButtons([
            .splitHorizontal, .splitVertical, .bottomDrawer, .rightDrawer, .scratch, .focusMode,
        ])
        XCTAssertEqual(dock.visibleLayoutForTesting, ["New tab", "│", "Command palette"])

        render(dock, OverlayState(rightBusy: true))
        XCTAssertEqual(
            dock.visibleLayoutForTesting,
            ["New tab", "│", "Toggle right drawer", "│", "Command palette"])
    }

    /// The stack order and recolor list derive from `ToolbarButton.groups` / `allCases`, so a case
    /// missing from `groups` would silently never mount. Order-sensitive on purpose: the groups
    /// flattened ARE the toolbar order.
    func test_toolbarButtonGroups_coverEveryCaseInOrder() {
        XCTAssertEqual(ToolbarButton.groups.flatMap { $0 }, ToolbarButton.allCases)
    }
}
