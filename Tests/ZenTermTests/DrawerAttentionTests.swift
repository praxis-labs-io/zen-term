import AppKit
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// A closed drawer is out of sight in the tab you are in, so it has to be able to ask for you there.
@MainActor
final class DrawerAttentionTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        var config = GeneralConfig.builtIn
        config.attentionToast = .sticky
        GeneralConfig.setCurrentForTesting(config)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        c.mountAndStart()
        controller = c
        return c
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    private func toastViews(_ c: WindowController) -> [ToastView] {
        guard let content = c.window.contentView else { return [] }
        return descendants(of: content).compactMap { $0 as? ToastView }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    /// Opens the right drawer once so its surface exists, then closes it.
    private func closedRightDrawer(_ c: WindowController) throws -> RecordingSurface {
        let before = spawned.count
        c.handle(.toggleRightDrawer)
        let drawer = try XCTUnwrap(spawned.dropFirst(before).first, "opening the drawer spawns its surface")
        c.handle(.toggleRightDrawer)
        drainMainQueue()
        return drawer
    }

    private func notify(_ surface: RecordingSurface) {
        surface.delegate?.surface(
            surface, didPostNotification: TerminalNotification(title: "claude", body: "needs you"))
        drainMainQueue()
    }

    func test_aClosedDrawerAsking_dotsItsButton() throws {
        let c = makeWindow()
        let drawer = try closedRightDrawer(c)

        notify(drawer)

        XCTAssertEqual(c.dockForTesting.rightActivityStateForTesting, .waiting)
        XCTAssertTrue(c.dockForTesting.rightActivityForTesting)
    }

    func test_aClosedDrawerAsking_raisesACard() throws {
        let c = makeWindow()
        let drawer = try closedRightDrawer(c)

        notify(drawer)

        XCTAssertEqual(toastViews(c).count, 1, "out of sight is out of sight, even in the tab you are in")
    }

    func test_openingTheDrawer_answersIt() throws {
        let c = makeWindow()
        let drawer = try closedRightDrawer(c)
        notify(drawer)

        c.handle(.toggleRightDrawer)
        drainMainQueue()

        XCTAssertEqual(c.dockForTesting.rightActivityStateForTesting, .idle)
        XCTAssertEqual(c.windowAttentionForTesting, .idle)
        XCTAssertTrue(toastViews(c).isEmpty, "the card goes once you are looking at what raised it")
    }

    func test_anOpenDrawerAsking_isAlreadySeen() throws {
        let c = makeWindow()
        let drawer = try closedRightDrawer(c)
        c.handle(.toggleRightDrawer)
        drainMainQueue()

        notify(drawer)

        XCTAssertEqual(c.windowAttentionForTesting, .idle)
        XCTAssertTrue(toastViews(c).isEmpty)
    }

    func test_aLongCommandFinishingInAClosedDrawer_dotsItPositive() throws {
        let c = makeWindow()
        let drawer = try closedRightDrawer(c)

        drawer.delegate?.surface(
            drawer, commandDidFinish: TerminalCommandResult(exitCode: 0, duration: 30))
        drainMainQueue()

        XCTAssertEqual(c.dockForTesting.rightActivityStateForTesting, .completed)
        XCTAssertEqual(
            c.dockForTesting.rightActivityColorForTesting, Theme.current.chrome.positive.nsColor)
    }

    func test_aPaneInTheActiveTab_isStillSeen() throws {
        let c = makeWindow()

        c.notifyAgentForTesting(tabIndex: 0, message: "needs you")
        drainMainQueue()

        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0), "a pane in the tab you are in is on screen")
        XCTAssertTrue(toastViews(c).isEmpty)
    }
}
