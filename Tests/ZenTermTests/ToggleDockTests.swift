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

    /// The stack order and recolor list derive from `ToolbarButton.groups` / `allCases`, so a case
    /// missing from `groups` would silently never mount. Order-sensitive on purpose: the groups
    /// flattened ARE the toolbar order.
    func test_toolbarButtonGroups_coverEveryCaseInOrder() {
        XCTAssertEqual(ToolbarButton.groups.flatMap { $0 }, ToolbarButton.allCases)
    }

    // MARK: - footer legibility

    /// The footer's ink is the only thing in the window that has to stay readable at any
    /// `backdrop-alpha`, and a composited alpha is exactly the budget an eye cannot check: a light
    /// theme over a dark desktop reads as "slightly dim" right up until it is unreadable.
    ///
    /// Source-over: `a` over `b` lands at `a + b(1 - a)`. Asserts the strip's own fill brings the
    /// shell to the floor across the range, rather than asserting the top-up numbers themselves.
    func test_theStripsFill_bringsTheShellToTheLegibilityFloor() {
        let floor = ToggleDock.legibilityFloor
        for backdrop in stride(from: CGFloat(0), through: 0.9, by: 0.1) {
            let fill = ToggleDock.fillAlpha(backdropAlpha: backdrop, floor: floor)
            let combined = fill + backdrop * (1 - fill)
            XCTAssertEqual(
                combined, floor, accuracy: 0.0001,
                "backdrop-alpha \(backdrop) composites to \(combined), not the \(floor) floor")
        }
    }

    /// A shell already at or past the floor is left exactly as it was, so the default look does not
    /// gain a bar that was never there.
    func test_aShellPastTheFloor_paintsNothing() {
        XCTAssertEqual(ToggleDock.fillAlpha(backdropAlpha: ToggleDock.legibilityFloor), 0)
        XCTAssertEqual(ToggleDock.fillAlpha(backdropAlpha: 1), 0)
    }

    /// The painted color, not the computed number: the strip has to actually carry a fill, and it has
    /// to be the theme's own background so it reads as the shell rather than a separate surface.
    @MainActor
    func test_theStrip_paintsTheThemeBackground_notATint() {
        let dock = makeDock([])
        let painted = try? XCTUnwrap(dock.paintedFillForTesting)
        XCTAssertNotNil(painted, "the strip carries a fill")
        guard let painted, let color = NSColor(cgColor: painted)?.usingColorSpace(.sRGB),
            let background = Theme.current.chrome.background.nsColor.usingColorSpace(.sRGB)
        else { return XCTFail("could not read the painted fill") }
        XCTAssertEqual(color.redComponent, background.redComponent, accuracy: 0.01)
        XCTAssertEqual(color.greenComponent, background.greenComponent, accuracy: 0.01)
        XCTAssertEqual(color.blueComponent, background.blueComponent, accuracy: 0.01)
    }
}
