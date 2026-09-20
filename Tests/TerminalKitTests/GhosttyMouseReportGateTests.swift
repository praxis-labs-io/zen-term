import AppKit
import XCTest

@testable import TerminalKit

final class GhosttyMouseReportGateTests: XCTestCase {
    private var window: NSWindow!
    private var container: NSView!
    private var view: GhosttyHostView!
    private var buttonsDown = 0

    private static let canvas = NSRect(x: 0, y: 0, width: 400, height: 300)
    private static let overPane = NSPoint(x: 200, y: 150)
    private static let retired = CGPoint(x: -1, y: -1)

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared

        window = NSWindow(
            contentRect: Self.canvas, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        container = NSView(frame: Self.canvas)
        view = GhosttyHostView(frame: Self.canvas)
        view.pressedMouseButtons = { [unowned self] in self.buttonsDown }
        container.addSubview(view)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
    }

    override func tearDown() {
        window.close()
        window = nil
        container = nil
        view = nil
        buttonsDown = 0
        super.tearDown()
    }

    func test_anUncoveredPaneReportsThePointer() throws {
        view.mouseMoved(with: try move(to: Self.overPane))

        XCTAssertEqual(view.mousePosPushesForTesting, 1)
        XCTAssertEqual(view.lastPushedMousePosForTesting, CGPoint(x: 200, y: 150))
    }

    // The cover arrives under a still pointer, so the next move is the only chance to retire the position.
    func test_theFirstMoveUnderACoverRetiresThePointerAndLaterMovesReportNothing() throws {
        view.mouseMoved(with: try move(to: Self.overPane))
        cover()

        view.mouseMoved(with: try move(to: NSPoint(x: 210, y: 150)))
        view.mouseMoved(with: try move(to: NSPoint(x: 220, y: 150)))

        XCTAssertEqual(view.mousePosPushesForTesting, 2, "a move under a cover reported a position")
        XCTAssertEqual(view.lastPushedMousePosForTesting, Self.retired)
    }

    func test_aPaneNeverReportedRetiresNothingUnderACover() throws {
        cover()

        view.mouseMoved(with: try move(to: Self.overPane))

        XCTAssertEqual(view.mousePosPushesForTesting, 0)
    }

    func test_reportingResumesWhenTheCoverGoes() throws {
        view.mouseMoved(with: try move(to: Self.overPane))
        let cover = cover()
        view.mouseMoved(with: try move(to: NSPoint(x: 210, y: 150)))

        cover.removeFromSuperview()
        view.mouseMoved(with: try move(to: NSPoint(x: 220, y: 150)))

        XCTAssertEqual(view.mousePosPushesForTesting, 3)
        XCTAssertEqual(view.lastPushedMousePosForTesting, CGPoint(x: 220, y: 150))
    }

    // A drag routes to the view its press landed on, so it outruns the gate wherever the pointer goes.
    func test_aDragThisPaneOwnsKeepsReportingOverACover() throws {
        view.mouseMoved(with: try move(to: Self.overPane))
        buttonsDown = 1
        view.mouseDown(with: try move(to: Self.overPane, type: .leftMouseDown))
        cover()

        view.mouseDragged(with: try move(to: NSPoint(x: 210, y: 150), type: .leftMouseDragged))

        XCTAssertEqual(view.mousePosPushesForTesting, 2)
        XCTAssertEqual(view.lastPushedMousePosForTesting, CGPoint(x: 210, y: 150))
    }

    // Tracking still delivers enter and exit mid-drag, so a drag in the cover must not ride the exemption.
    func test_aDragAnotherViewOwnsDoesNotReportOverACover() throws {
        view.mouseMoved(with: try move(to: Self.overPane))
        cover()
        buttonsDown = 1

        view.mouseEntered(with: try enterExit(.mouseEntered, at: NSPoint(x: 210, y: 150)))

        XCTAssertEqual(view.mousePosPushesForTesting, 2)
        XCTAssertEqual(view.lastPushedMousePosForTesting, Self.retired)
    }

    func test_aReleaseThisPaneNeverSawCannotStrandTheGateOpen() throws {
        view.mouseMoved(with: try move(to: Self.overPane))
        buttonsDown = 1
        view.mouseDown(with: try move(to: Self.overPane, type: .leftMouseDown))
        cover()

        buttonsDown = 0
        view.mouseMoved(with: try move(to: NSPoint(x: 210, y: 150)))

        XCTAssertEqual(view.mousePosPushesForTesting, 2)
        XCTAssertEqual(view.lastPushedMousePosForTesting, Self.retired)
    }

    func test_exitRetiresThePointerOnlyWhenNoButtonIsDown() throws {
        view.mouseMoved(with: try move(to: Self.overPane))
        buttonsDown = 1

        view.mouseExited(with: try enterExit(.mouseExited, at: NSPoint(x: 500, y: 150)))
        XCTAssertEqual(view.mousePosPushesForTesting, 1)

        buttonsDown = 0
        view.mouseExited(with: try enterExit(.mouseExited, at: NSPoint(x: 500, y: 150)))
        XCTAssertEqual(view.mousePosPushesForTesting, 2)
        XCTAssertEqual(view.lastPushedMousePosForTesting, Self.retired)
    }

    // Reactivation synthesizes no `mouseEntered`, so the parked pointer is re-reported by hand.
    func test_theParkedPointerIsReportedOnlyWhenNothingCoversIt() {
        view.reportParkedPointer(at: Self.overPane)

        XCTAssertEqual(view.mousePosPushesForTesting, 1)
        XCTAssertEqual(view.lastPushedMousePosForTesting, CGPoint(x: 200, y: 150))
    }

    func test_theParkedPointerIsNotReportedUnderACover() {
        cover()

        view.reportParkedPointer(at: Self.overPane)

        XCTAssertEqual(view.mousePosPushesForTesting, 0)
    }

    // The parked pointer takes no drag exemption: a pane owning a drag must not report from outside its own bounds.
    func test_theParkedPointerIsNotReportedWhileThisPaneOwnsADrag() throws {
        view.mouseMoved(with: try move(to: Self.overPane))
        buttonsDown = 1
        view.mouseDown(with: try move(to: Self.overPane, type: .leftMouseDown))
        cover()

        view.reportParkedPointer(at: Self.overPane)

        XCTAssertEqual(view.mousePosPushesForTesting, 1)
    }

    // The window check is per window, so a held button must not let every pane in it report.
    func test_theParkedPointerIsNotReportedUnderACoverWhileAButtonIsHeld() {
        cover()
        buttonsDown = 1

        view.reportParkedPointer(at: Self.overPane)

        XCTAssertEqual(view.mousePosPushesForTesting, 0)
    }

    // A backdrop pinned over the whole canvas, as every overlay kind builds one.
    @discardableResult
    private func cover() -> NSView {
        let backdrop = NSView(frame: Self.canvas)
        container.addSubview(backdrop)
        return backdrop
    }

    private func move(to point: NSPoint, type: NSEvent.EventType = .mouseMoved) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0,
                pressure: 0))
    }

    private func enterExit(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                userData: nil))
    }
}
