import AppKit
import TabKit
import XCTest

@testable import ZenTerm

final class ToggleDockTests: XCTestCase {
    private func float(_ id: String, order: Int = 0) -> ToolFloat {
        ToolFloat(
            id: id, order: order, title: id, icon: "square.on.square", command: "cmd", dir: nil,
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
            persist: .ephemeral, toggle: Chord(command: true, shift: true, key: "d"))
    }

    private func makeDock(_ floats: [ToolFloat]) -> ToggleDock {
        ToggleDock(
            onNewTab: {}, onSplitH: {}, onSplitV: {}, onBottom: {}, onRight: {},
            onZoom: {}, toolFloats: floats, onToolFloat: { _ in })
    }

    func test_setToolFloats_rebuildsButtonsForCatalog() {
        let dock = makeDock([float("dev")])
        XCTAssertEqual(dock.toolFloatButtonIDsForTesting, ["dev"])

        dock.setToolFloats([float("dev"), float("top")])
        XCTAssertEqual(dock.toolFloatButtonIDsForTesting, ["dev", "top"])

        dock.setToolFloats([float("top")])
        XCTAssertEqual(dock.toolFloatButtonIDsForTesting, ["top"])

        dock.setToolFloats([])
        XCTAssertTrue(dock.toolFloatButtonIDsForTesting.isEmpty)
    }

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
        dock.render(overlay: overlay, floatID: nil)
        XCTAssertTrue(dock.bottomActivityForTesting, "a busy bottom drawer must dot its toggle")
        XCTAssertFalse(dock.rightActivityForTesting)

        overlay.bottomBusy = false
        overlay.rightBusy = true
        dock.render(overlay: overlay, floatID: nil)
        XCTAssertFalse(dock.bottomActivityForTesting)
        XCTAssertTrue(dock.rightActivityForTesting)
    }

    func test_render_aWaitingDrawer_dotsItsToggleEvenWhenIdle() {
        let dock = makeDock([])

        dock.render(
            overlay: OverlayState(), floatID: nil, tab: nil,
            drawerAttention: { $0 == .right ? .waiting : .idle })

        XCTAssertTrue(
            dock.rightActivityForTesting,
            "a hidden drawer holding a blocked agent has to say so, busy or not")
        XCTAssertEqual(dock.rightActivityStateForTesting, .waiting)
    }

    func test_render_theDotTakesTheAttentionColor() {
        let dock = makeDock([])
        let chrome = Theme.current.chrome

        dock.render(
            overlay: OverlayState(), floatID: nil, tab: nil,
            drawerAttention: { _ in .waiting })
        XCTAssertEqual(dock.rightActivityColorForTesting, chrome.attention.nsColor)

        dock.render(
            overlay: OverlayState(), floatID: nil, tab: nil,
            drawerAttention: { _ in .completed })
        XCTAssertEqual(dock.rightActivityColorForTesting, chrome.positive.nsColor)
    }

    func test_render_aBusyDrawerWithNothingPending_keepsTheNeutralDot() {
        let dock = makeDock([])
        var overlay = OverlayState()
        overlay.rightBusy = true

        dock.render(
            overlay: overlay, floatID: nil, tab: nil,
            drawerAttention: { _ in .working })

        XCTAssertTrue(dock.rightActivityForTesting)
        XCTAssertEqual(
            dock.rightActivityColorForTesting, Theme.current.chrome.accent.nsColor,
            "working is not asking for you, so the dot stays the colour it has always been")
    }

    func test_render_aWaitingFloat_dotsItsButton() {
        let dock = makeDock([float("dev")])

        dock.render(
            overlay: OverlayState(), floatID: nil, tab: nil,
            floatAttention: { $0 == "dev" ? .waiting : .idle })

        XCTAssertEqual(dock.dottedToolFloatIDsForTesting, ["dev"])
    }

    func test_render_dotShowsEvenWhileDrawerOpen() {
        let dock = makeDock([])
        var overlay = OverlayState()
        overlay.isBottomOpen = true
        overlay.bottomBusy = true
        dock.render(overlay: overlay, floatID: nil)
        XCTAssertTrue(dock.bottomActivityForTesting)
    }

    func test_render_noDotWhenIdle() {
        let dock = makeDock([])
        dock.render(overlay: OverlayState(), floatID: nil)
        XCTAssertFalse(dock.bottomActivityForTesting)
        XCTAssertFalse(dock.rightActivityForTesting)
    }

    func test_render_dotsFloatsLiveInBackground_notTheShownOne() {
        let dock = makeDock([float("dev"), float("top")])

        dock.render(
            overlay: OverlayState(), floatID: "dev",
            isLiveInBackground: { $0 == "top" })

        XCTAssertEqual(dock.dottedToolFloatIDsForTesting, ["top"])
    }

    func test_render_noLiveFloats_noDots() {
        let dock = makeDock([float("dev")])
        dock.render(overlay: OverlayState(), floatID: nil)
        XCTAssertTrue(dock.dottedToolFloatIDsForTesting.isEmpty)
    }

    func test_render_dotClearsWhenTheFloatIsNoLongerLive() {
        let dock = makeDock([float("top")])
        dock.render(
            overlay: OverlayState(), floatID: nil, isLiveInBackground: { _ in true })
        XCTAssertEqual(dock.dottedToolFloatIDsForTesting, ["top"])

        dock.render(
            overlay: OverlayState(), floatID: nil, isLiveInBackground: { _ in false })

        XCTAssertTrue(dock.dottedToolFloatIDsForTesting.isEmpty, "a re-render after exit clears the dot")
    }

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
            onNewTab: {}, onSplitH: {}, onSplitV: {}, onBottom: {}, onRight: {},
            onZoom: {}, toolFloats: [], onToolFloat: { toggled.append($0.id) })

        press("Scratch", in: dock)

        XCTAssertEqual(toggled, ["scratch"])
    }

    func test_render_scratchButtonStaysLitWhileItsOwnCardIsUp() {
        let dock = makeDock([])
        var overlay = OverlayState()
        overlay.isBottomOpen = true

        dock.render(overlay: overlay, floatID: "scratch")

        XCTAssertTrue(dock.scratchActiveForTesting, "the button IS the card, so it must stay lit")
        XCTAssertFalse(dock.scratchActivityForTesting, "shown, so no background dot")
    }

    func test_render_scratchButtonIsDarkWhileAnotherFloatsCardIsUp() {
        let dock = makeDock([float("dev")])

        dock.render(overlay: OverlayState(), floatID: "dev")

        XCTAssertFalse(dock.scratchActiveForTesting)
    }

    func test_render_dotsScratchWhileItRunsHidden() {
        let dock = makeDock([])

        dock.render(
            overlay: OverlayState(), floatID: nil,
            isLiveInBackground: { $0 == "scratch" })
        XCTAssertTrue(dock.scratchActivityForTesting)

        dock.render(overlay: OverlayState(), floatID: nil)
        XCTAssertFalse(dock.scratchActivityForTesting, "a re-render after exit clears the dot")
    }

    func test_newTabButton_isMounted() {
        XCTAssertTrue(makeDock([]).hasNewTabButtonForTesting)
    }

    private static let fixedDefault = [
        "New tab", "│",
        "Split horizontally", "Split vertically", "Toggle bottom drawer", "Toggle right drawer",
        "Scratch", "Focus mode",
    ]

    func test_defaultLayout_groupsWithOneDivider_noTrailingDivider() {
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
                "Focus mode",
            ])

        dock.setHiddenButtons([])
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)
    }

    func test_emptyMiddleGroup_collapsesToOneDivider() {
        let dock = makeDock([float("dev")])
        dock.setHiddenButtons([
            .splitHorizontal, .splitVertical, .bottomDrawer, .rightDrawer, .scratch, .focusMode,
        ])
        XCTAssertEqual(
            dock.visibleLayoutForTesting, ["New tab", "│", "dev"])
    }

    func test_hiddenFirstGroup_leavesNoLeadingDivider() {
        let dock = makeDock([])
        dock.setHiddenButtons([.newTab])
        XCTAssertEqual(
            dock.visibleLayoutForTesting,
            [
                "Split horizontally", "Split vertically", "Toggle bottom drawer",
                "Toggle right drawer", "Scratch", "Focus mode",
            ])
    }

    func test_everyFixedButtonHidden_showsNothing_andFloatsStandAlone() {
        let dock = makeDock([])
        dock.setHiddenButtons(Set(ToolbarButton.allCases))
        XCTAssertTrue(dock.visibleLayoutForTesting.isEmpty)

        dock.setToolFloats([float("dev")])
        XCTAssertEqual(dock.visibleLayoutForTesting, ["dev"])
    }

    func test_hiddenNewTab_reportsNotMounted() {
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

        dock.render(overlay: OverlayState(), floatID: nil)
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)
    }

    func test_hiddenFloat_surfacesWhileLiveInBackground_andRehidesWhenItDies() {
        var hidden = float("dev")
        hidden.showsInToolbar = false
        let dock = makeDock([hidden])
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)

        dock.render(
            overlay: OverlayState(), floatID: nil,
            isLiveInBackground: { $0 == "dev" })
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault + ["│", "dev"])
        XCTAssertEqual(dock.dottedToolFloatIDsForTesting, ["dev"])

        dock.render(overlay: OverlayState(), floatID: nil)
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault, "the handle leaves with the process")
    }

    func test_hiddenFloat_surfacesWhileItsCardIsShown() {
        var hidden = float("dev")
        hidden.showsInToolbar = false
        let dock = makeDock([hidden])

        dock.render(overlay: OverlayState(), floatID: "dev")
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault + ["│", "dev"])
    }

    private static let bottomHidden = fixedDefault.filter { $0 != "Toggle bottom drawer" }
    private static let scratchHidden = fixedDefault.filter { $0 != "Scratch" }

    private func render(
        _ dock: ToggleDock, _ overlay: OverlayState = OverlayState(), floatID: String? = nil,
        tab: TabID? = nil, scratchBusy: Bool = false, scratchLive: Bool = false
    ) {
        dock.render(
            overlay: overlay, floatID: floatID, tab: tab,
            isLiveInBackground: { scratchLive && $0 == ToolFloat.scratch.id },
            isFloatBusy: { scratchBusy && $0 == ToolFloat.scratch.id })
    }

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

    func test_hiddenDrawer_surfacesWhileItsFinishedCommandIsUnseen() {
        let dock = makeDock([])
        dock.setHiddenButtons([.bottomDrawer])

        dock.render(
            overlay: OverlayState(), floatID: nil, tab: nil,
            drawerAttention: { $0 == .bottom ? .completed : .idle })

        XCTAssertEqual(
            dock.visibleLayoutForTesting, Self.fixedDefault,
            "the command is done so nothing is busy, but it is still asking to be seen")
        XCTAssertTrue(dock.bottomActivityForTesting)
    }

    func test_hiddenDrawer_rehidesOnceItsAttentionIsAnswered() {
        let dock = makeDock([])
        dock.setHiddenButtons([.bottomDrawer])
        dock.render(
            overlay: OverlayState(), floatID: nil, tab: nil,
            drawerAttention: { $0 == .bottom ? .waiting : .idle })

        render(dock)

        XCTAssertEqual(dock.visibleLayoutForTesting, Self.bottomHidden)
    }

    func test_hiddenDrawer_staysHiddenWhileIdleAndOpen() {
        let dock = makeDock([])
        dock.setHiddenButtons([.bottomDrawer])

        render(dock, OverlayState(isBottomOpen: true))
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.bottomHidden)
    }

    func test_hiddenDrawer_staysHiddenWhileBusyAndOnScreen() {
        let dock = makeDock([])
        dock.setHiddenButtons([.bottomDrawer])

        render(dock, OverlayState(isBottomOpen: true, bottomBusy: true))
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.bottomHidden)
    }

    func test_surfacedDrawer_holdsWhileYouOpenAndUseIt() {
        let dock = makeDock([])
        dock.setHiddenButtons([.bottomDrawer])
        render(dock, OverlayState(bottomBusy: true))
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)

        render(dock, OverlayState(isBottomOpen: true, bottomBusy: true))
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault, "vanished as it was pressed")

        render(dock, OverlayState(isBottomOpen: true))
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault, "vanished while on screen")

        render(dock)
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.bottomHidden)
    }

    func test_surfacedDrawer_doesNotFollowATabSwitch() {
        let dock = makeDock([])
        dock.setHiddenButtons([.bottomDrawer])
        render(dock, OverlayState(bottomBusy: true), tab: TabID(1))
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)

        render(dock, OverlayState(isBottomOpen: true), tab: TabID(2))
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.bottomHidden)

        render(dock, OverlayState(bottomBusy: true), tab: TabID(1))
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault, "still working back here")
    }

    func test_hiddenDrawer_surfacesWhileBusyAndZoomedAway() {
        let dock = makeDock([])
        dock.setHiddenButtons([.bottomDrawer])

        render(dock, OverlayState(isBottomOpen: true, zoomed: .pane, bottomBusy: true))
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)
    }

    func test_hiddenDrawer_staysHiddenWhileIdleAndClosed() {
        let dock = makeDock([])
        dock.setHiddenButtons([.rightDrawer])

        render(dock)
        XCTAssertEqual(
            dock.visibleLayoutForTesting, Self.fixedDefault.filter { $0 != "Toggle right drawer" })
    }

    func test_shownDrawer_isUnaffectedByBusy() {
        let dock = makeDock([])

        render(dock, OverlayState(bottomBusy: true, rightBusy: true))
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)
    }

    func test_hidingABusyDrawer_leavesItOnScreen() {
        let dock = makeDock([])
        dock.setHiddenButtons([.bottomDrawer])
        render(dock, OverlayState(bottomBusy: true))

        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)
    }

    func test_hidingAnIdleDrawer_isNotBlockedByAnEarlierBusySpell() {
        let dock = makeDock([])
        render(dock, OverlayState(bottomBusy: true))
        render(dock, OverlayState(isBottomOpen: true))

        dock.setHiddenButtons([.bottomDrawer])
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.bottomHidden)
    }

    func test_hiddenScratch_surfacesWhileBusy_notMerelyLive() {
        let dock = makeDock([])
        dock.setHiddenButtons([.scratch])

        render(dock, scratchLive: true)
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.scratchHidden)

        render(dock, scratchBusy: true, scratchLive: true)
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.fixedDefault)
        XCTAssertTrue(dock.scratchActivityForTesting)
    }

    func test_hiddenScratch_staysHiddenWhileItsOwnCardIsUp() {
        let dock = makeDock([])
        dock.setHiddenButtons([.scratch])

        render(dock, floatID: ToolFloat.scratch.id, scratchBusy: true)
        XCTAssertEqual(dock.visibleLayoutForTesting, Self.scratchHidden)
    }

    func test_surfacedDrawer_bringsBackItsGroupDivider() {
        let dock = makeDock([])
        dock.setHiddenButtons([
            .splitHorizontal, .splitVertical, .bottomDrawer, .rightDrawer, .scratch, .focusMode,
        ])
        XCTAssertEqual(dock.visibleLayoutForTesting, ["New tab"])

        render(dock, OverlayState(rightBusy: true))
        XCTAssertEqual(dock.visibleLayoutForTesting, ["New tab", "│", "Toggle right drawer"])
    }

    func test_toolbarGroupsThenSidebarFooter_coverEveryCaseInOrder() {
        XCTAssertEqual(ToolbarButton.groups.flatMap { $0 } + ToolbarButton.sidebarFooter, ToolbarButton.allCases)
    }
}
