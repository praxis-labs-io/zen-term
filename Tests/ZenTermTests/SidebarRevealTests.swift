import AppKit
import PaneKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class SidebarRevealTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controllers: [WindowController] = []
    private var originalConfig: GeneralConfig!

    private static let gutter: CGFloat = 20
    private var originalHold: TimeInterval = 0
    private var originalGrace: TimeInterval = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalConfig = GeneralConfig.current
        var config = GeneralConfig.builtIn
        config.windowGutter = Self.gutter
        GeneralConfig.setCurrentForTesting(config)
        Motion.isReduceMotionEnabled = { true }
        SidebarController.resetLastChoiceForTesting()
        GitRepoStatus.resetForTesting()
        originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        originalHold = SidebarEdgeReveal.holdDelay
        originalGrace = SidebarEdgeReveal.exitGrace
        SidebarEdgeReveal.holdDelay = 0.02
        SidebarEdgeReveal.exitGrace = 0.02
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        controllers = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        SidebarController.resetLastChoiceForTesting()
        GitRepoStatus.resetForTesting()
        GeneralConfig.setCurrentForTesting(originalConfig)
        SidebarEdgeReveal.holdDelay = originalHold
        SidebarEdgeReveal.exitGrace = originalGrace
        try super.tearDownWithError()
    }

    private func makeCollapsedController() throws -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        controllers.append(controller)
        controller.mountAndStart()
        try click(controller.sidebarForTesting.toggleButtonForTesting)
        XCTAssertFalse(controller.sidebarForTesting.isDocked)
        return controller
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func frame(of view: NSView, in controller: WindowController) -> NSRect {
        controller.containerForTesting.layoutSubtreeIfNeeded()
        return view.convert(view.bounds, to: controller.containerForTesting)
    }

    private func pane(in controller: WindowController) throws -> PanelHostView {
        try XCTUnwrap(controller.focusedPanelForTesting)
    }

    private func click(_ button: IconButton) throws {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: button.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        button.mouseDown(with: event)
    }

    private func settle() {
        let done = expectation(description: "the fade finishes")
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.pageSlideDuration + 0.15) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func test_reveal_floatsTheCardAtTheGutter_withoutMovingThePanes() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        let paneBefore = frame(of: try pane(in: controller), in: controller)

        sidebar.reveal()

        XCTAssertTrue(sidebar.isRevealed)
        let card = frame(of: sidebar.column, in: controller)
        let container = controller.containerForTesting.bounds
        XCTAssertEqual(card.minX, Self.gutter)
        XCTAssertEqual(card.width, SidebarView.width)
        XCTAssertEqual(card.minY, Self.gutter, "the card clears the bottom gutter")
        XCTAssertEqual(card.maxY, container.height - ChromeMetrics.topInset, "the top clears the traffic lights")
        XCTAssertEqual(
            frame(of: try pane(in: controller), in: controller), paneBefore,
            "the card floats over the panes, so nothing reflows and no surface resizes")
    }

    func test_reveal_dressesTheColumnAsACard_andCoversTheCollapsedLead() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting

        XCTAssertFalse(sidebar.lead.isHidden, "collapsed, the workspace name leads the tab bar")

        sidebar.reveal()

        XCTAssertTrue(sidebar.column.isFloating)
        XCTAssertEqual(sidebar.column.layer?.cornerRadius, CardChrome.cornerRadius)
        XCTAssertNotNil(sidebar.column.shadow)
        XCTAssertFalse(sidebar.view.isHidden)
        XCTAssertTrue(sidebar.lead.isHidden, "the name would otherwise render on top of the card")
    }

    func test_reveal_neverChangesTheDockedChoice() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting

        sidebar.reveal()
        XCTAssertFalse(sidebar.isDocked)

        sidebar.hideReveal()
        settle()

        XCTAssertFalse(sidebar.isDocked)
        XCTAssertFalse(sidebar.isRevealed)
    }

    func test_hideReveal_returnsTheColumnFlushAndUndressed() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.reveal()

        sidebar.hideReveal()
        settle()

        XCTAssertFalse(sidebar.column.isFloating)
        XCTAssertEqual(frame(of: sidebar.column, in: controller).minX, 0)
        XCTAssertTrue(sidebar.view.isHidden)
        XCTAssertFalse(sidebar.lead.isHidden, "the workspace name comes back")
        XCTAssertEqual(sidebar.column.layer?.opacity, 1, "or the toggle's column stays faded out")
    }

    func test_dockingARevealedCard_landsDockedWithNoCardChrome() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.reveal()

        try click(sidebar.toggleButtonForTesting)

        XCTAssertTrue(sidebar.isDocked)
        XCTAssertFalse(sidebar.isRevealed)
        XCTAssertFalse(sidebar.column.isFloating)
        XCTAssertEqual(frame(of: sidebar.column, in: controller).minX, 0)
        XCTAssertEqual(
            frame(of: try pane(in: controller), in: controller).minX > Self.gutter, true,
            "docking pushes the canvas, which revealing never does")
    }

    func test_collapsedColumn_passesClicksThroughToThePanes() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        controller.containerForTesting.layoutSubtreeIfNeeded()
        let inside = NSPoint(x: sidebar.column.bounds.midX, y: sidebar.column.bounds.midY)

        XCTAssertNil(
            sidebar.column.hitTest(sidebar.column.convert(inside, to: controller.containerForTesting)),
            "collapsed, the column is an empty frame over the canvas")

        sidebar.reveal()

        XCTAssertNotNil(
            sidebar.column.hitTest(sidebar.column.convert(inside, to: controller.containerForTesting)),
            "revealed, a click on the card must not reach the pane under it")
    }

    private func enterStrip(_ reveal: SidebarEdgeReveal) throws {
        reveal.stripForTesting.mouseEntered(with: try enterExitEvent(.mouseEntered, on: reveal))
    }

    private func leaveStrip(_ reveal: SidebarEdgeReveal, at point: NSPoint) throws {
        let strip = reveal.stripForTesting
        let inWindow = strip.convert(point, to: nil)
        let event = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .mouseExited, location: inWindow, modifierFlags: [], timestamp: 0,
                windowNumber: strip.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                trackingNumber: 0, userData: nil))
        strip.mouseExited(with: event)
    }

    private func leaveStripRight(_ reveal: SidebarEdgeReveal) throws {
        let strip = reveal.stripForTesting
        try leaveStrip(reveal, at: NSPoint(x: strip.bounds.maxX + 4, y: strip.bounds.midY))
    }

    private func enterExitEvent(_ type: NSEvent.EventType, on reveal: SidebarEdgeReveal) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: reveal.stripForTesting.window?.windowNumber ?? 0, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    private func afterTimers() {
        let done = expectation(description: "the hold and grace fire")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func test_restingAtTheEdge_revealsAfterTheHold() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.edgeReveal.pointerIsInside = { true }

        try enterStrip(sidebar.edgeReveal)
        XCTAssertFalse(sidebar.isRevealed, "a pointer passing the edge must not flash the card")

        afterTimers()

        XCTAssertTrue(sidebar.isRevealed)
    }

    func test_leavingBeforeTheHold_neverReveals() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.edgeReveal.pointerIsInside = { true }

        try enterStrip(sidebar.edgeReveal)
        try leaveStripRight(sidebar.edgeReveal)
        afterTimers()

        XCTAssertFalse(sidebar.isRevealed)
    }

    func test_docked_theEdgeNeverArms() throws {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        controllers.append(controller)
        controller.mountAndStart()
        let sidebar = controller.sidebarForTesting
        sidebar.edgeReveal.pointerIsInside = { true }
        XCTAssertTrue(sidebar.isDocked)

        try enterStrip(sidebar.edgeReveal)
        afterTimers()

        XCTAssertFalse(sidebar.isRevealed)
    }

    func test_leavingTheCard_hidesItAfterTheGrace() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.edgeReveal.pointerIsInside = { false }
        sidebar.reveal()

        try leaveStripRight(sidebar.edgeReveal)
        afterTimers()

        XCTAssertFalse(sidebar.isRevealed)
    }

    func test_focusInsideTheCard_pinsItAgainstAnExit() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.edgeReveal.pointerIsInside = { false }
        sidebar.reveal()
        let row = try XCTUnwrap(sidebar.view.rowsForTesting.first)
        row.takeKeyboardFocus()

        try leaveStripRight(sidebar.edgeReveal)
        afterTimers()

        XCTAssertTrue(sidebar.isRevealed, "the card keeps the keyboard it was given")
    }

    func test_anOpenRowMenu_pinsTheCard_andClosingItRechecks() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.edgeReveal.pointerIsInside = { false }
        sidebar.reveal()
        sidebar.setHoverCovered(true)

        try leaveStripRight(sidebar.edgeReveal)
        afterTimers()
        XCTAssertTrue(sidebar.isRevealed, "a menu takes the pointer off the card without ending the reveal")

        sidebar.setHoverCovered(false)
        afterTimers()

        XCTAssertFalse(sidebar.isRevealed, "closing it sends no mouse event, so the close has to recheck")
    }

    func test_theHotZone_tracksItsOwnBounds_restingAndGrown() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        let strip = sidebar.edgeReveal.stripForTesting
        controller.containerForTesting.layoutSubtreeIfNeeded()

        XCTAssertEqual(strip.trackingAreas.count, 1)
        XCTAssertEqual(strip.trackingAreas.first?.rect, strip.bounds, "resting, the band is what it tracks")
        let resting = frame(of: strip, in: controller)
        XCTAssertEqual(resting.minX, 0)

        sidebar.reveal()
        controller.containerForTesting.layoutSubtreeIfNeeded()

        let grown = frame(of: strip, in: controller)
        XCTAssertEqual(
            grown.width, Self.gutter + SidebarView.width,
            "revealed, the live region has to span the gutter and the card")
        XCTAssertEqual(
            strip.trackingAreas.first?.rect, strip.bounds,
            "the area has to follow the resize, or the grown region is tracked at its old width")
    }

    func test_overshootingTheWindowEdge_keepsTheCard() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.edgeReveal.pointerIsInside = { false }
        sidebar.reveal()
        let strip = sidebar.edgeReveal.stripForTesting

        try leaveStrip(sidebar.edgeReveal, at: NSPoint(x: -6, y: strip.bounds.midY))
        afterTimers()

        XCTAssertTrue(
            sidebar.isRevealed,
            "running off the window's own edge is reaching for the card, not leaving it")
    }

    func test_leavingPastTheCard_putsItAway() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.edgeReveal.pointerIsInside = { false }
        sidebar.reveal()

        try leaveStripRight(sidebar.edgeReveal)
        afterTimers()

        XCTAssertFalse(sidebar.isRevealed)
    }

    func test_leavingThroughTheTop_putsItAway() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.edgeReveal.pointerIsInside = { false }
        sidebar.reveal()
        let strip = sidebar.edgeReveal.stripForTesting

        try leaveStrip(sidebar.edgeReveal, at: NSPoint(x: -6, y: strip.bounds.maxY + 4))
        afterTimers()

        XCTAssertFalse(sidebar.isRevealed, "a corner exit is still an exit")
    }

    func test_sweepingOffTheWindowEdge_stillReveals() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.edgeReveal.pointerIsInside = { false }
        let strip = sidebar.edgeReveal.stripForTesting

        try enterStrip(sidebar.edgeReveal)
        try leaveStrip(sidebar.edgeReveal, at: NSPoint(x: -6, y: strip.bounds.midY))
        afterTimers()

        XCTAssertTrue(
            sidebar.isRevealed,
            "carrying on past the edge mid-hold is still a reach for the card")
    }

    func test_sweepingOffTheTop_cancelsTheHold() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.edgeReveal.pointerIsInside = { false }
        let strip = sidebar.edgeReveal.stripForTesting

        try enterStrip(sidebar.edgeReveal)
        try leaveStrip(sidebar.edgeReveal, at: NSPoint(x: -6, y: strip.bounds.maxY + 4))
        afterTimers()

        XCTAssertFalse(sidebar.isRevealed)
    }

    func test_revealing_dimsThePanesHalo_withoutTakingItsKeyboard() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        let panel = try pane(in: controller)
        XCTAssertGreaterThan(panel.haloOpacityForTesting, 0, "the focused pane glows before the card is up")

        sidebar.reveal()

        XCTAssertEqual(panel.haloOpacityForTesting, 0, "the card is what reads as active")
        XCTAssertFalse(sidebar.hasFocus, "hover is a mouse gesture, so Esc still reaches the pane")

        sidebar.hideReveal()

        XCTAssertGreaterThan(panel.haloOpacityForTesting, 0, "and the pane takes it back")
    }

    func test_aModalOnScreen_stopsTheEdgeArming() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.edgeReveal.pointerIsInside = { true }

        controller.handle(.openSettings)
        XCTAssertTrue(controller.isModalOverlayOpen)

        try enterStrip(sidebar.edgeReveal)
        afterTimers()

        XCTAssertFalse(
            sidebar.isRevealed,
            "tracking is geometric, so a modal covering the strip does not stop it on its own")
    }

    func test_aToolFloatOnScreen_stopsTheEdgeArming() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.edgeReveal.pointerIsInside = { true }
        XCTAssertFalse(sidebar.edgeReveal.isSuppressed(), "nothing is covering the panes yet")

        controller.handle(.openSettings)

        XCTAssertTrue(sidebar.edgeReveal.isSuppressed(), "the gate is wired to the window's own modal state")
    }

    func test_clickingOutsideTheCard_hidesIt_withoutEatingTheClick() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.edgeReveal.pointerIsInside = { false }
        sidebar.reveal()
        controller.containerForTesting.layoutSubtreeIfNeeded()

        let strip = sidebar.edgeReveal.stripForTesting
        let outside = strip.convert(NSPoint(x: strip.bounds.maxX + 200, y: strip.bounds.midY), to: nil)
        let click = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: outside, modifierFlags: [], timestamp: 0,
                windowNumber: controller.window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))

        let passedThrough = sidebar.edgeReveal.clickForTesting(click)

        XCTAssertFalse(sidebar.isRevealed, "a click in a pane puts the card away")
        XCTAssertTrue(passedThrough === click, "and the monitor hands the click on to the pane it was aimed at")
    }

    func test_clickingInsideTheCard_keepsIt() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.edgeReveal.pointerIsInside = { false }
        sidebar.reveal()
        controller.containerForTesting.layoutSubtreeIfNeeded()

        let strip = sidebar.edgeReveal.stripForTesting
        let inside = strip.convert(NSPoint(x: strip.bounds.midX, y: strip.bounds.midY), to: nil)
        let click = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: inside, modifierFlags: [], timestamp: 0,
                windowNumber: controller.window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))

        _ = sidebar.edgeReveal.clickForTesting(click)

        XCTAssertTrue(sidebar.isRevealed, "clicking a row must not dismiss the card under the pointer")
    }
}
