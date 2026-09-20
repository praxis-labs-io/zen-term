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

    private func leaveStrip(_ reveal: SidebarEdgeReveal) throws {
        reveal.stripForTesting.mouseExited(with: try enterExitEvent(.mouseExited, on: reveal))
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
        try leaveStrip(sidebar.edgeReveal)
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

        try leaveStrip(sidebar.edgeReveal)
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

        try leaveStrip(sidebar.edgeReveal)
        afterTimers()

        XCTAssertTrue(sidebar.isRevealed, "the card keeps the keyboard it was given")
    }

    func test_anOpenRowMenu_pinsTheCard_andClosingItRechecks() throws {
        let controller = try makeCollapsedController()
        let sidebar = controller.sidebarForTesting
        sidebar.edgeReveal.pointerIsInside = { false }
        sidebar.reveal()
        sidebar.setHoverCovered(true)

        try leaveStrip(sidebar.edgeReveal)
        afterTimers()
        XCTAssertTrue(sidebar.isRevealed, "a menu takes the pointer off the card without ending the reveal")

        sidebar.setHoverCovered(false)
        afterTimers()

        XCTAssertFalse(sidebar.isRevealed, "closing it sends no mouse event, so the close has to recheck")
    }
}
