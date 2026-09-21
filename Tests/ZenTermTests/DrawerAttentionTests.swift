import AppKit
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class DrawerAttentionTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private let originalPresence = WindowController.isPresent

    override func setUpWithError() throws {
        try super.setUpWithError()
        WindowController.isPresent = { _ in true }
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
        WindowController.isPresent = originalPresence
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

    func test_aDrawersCard_namesItsTabAndTheDrawer() throws {
        let c = makeWindow()
        let drawer = try closedRightDrawer(c)
        let tab = try XCTUnwrap(c.tabTitleForTesting(index: 0))

        notify(drawer)

        let copy = toastViews(c).flatMap { descendants(of: $0) }
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(copy.contains(tab), "got \(copy)")
        XCTAssertTrue(copy.contains(": right drawer"), "got \(copy)")
    }

    func test_switchOnADrawersCard_opensTheDrawer() throws {
        let c = makeWindow()
        let drawer = try closedRightDrawer(c)
        notify(drawer)
        let card = try XCTUnwrap(toastViews(c).first)
        let switchButton = try XCTUnwrap(
            descendants(of: card).compactMap { $0 as? AppButton }.first { $0.title == "Switch" })

        switchButton.performClick(nil)
        drainMainQueue()

        XCTAssertTrue(
            c.dockForTesting.rightActiveForTesting,
            "you are already in this tab, so Switch has to open the drawer or it does nothing")
        XCTAssertTrue(toastViews(c).isEmpty)
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

    func test_aClosedDrawerWorking_dotsItsButton_andClearingLowersIt() throws {
        let c = makeWindow()
        let drawer = try closedRightDrawer(c)

        drawer.delegate?.surface(drawer, progressDidChange: TerminalProgress(state: .indeterminate))
        drainMainQueue()
        XCTAssertEqual(c.dockForTesting.rightActivityStateForTesting, .working)

        drawer.delegate?.surface(drawer, progressDidChange: nil)
        drainMainQueue()
        XCTAssertEqual(c.dockForTesting.rightActivityStateForTesting, .idle)
    }

    func test_visitingTheTab_leavesAClosedDrawerAsking() throws {
        let c = makeWindow()
        let drawer = try closedRightDrawer(c)
        c.newTabForTesting()
        notify(drawer)

        c.selectTabForTesting(index: 0)
        drainMainQueue()

        XCTAssertEqual(c.dockForTesting.rightActivityStateForTesting, .waiting)
        XCTAssertEqual(toastViews(c).count, 1, "the drawer is still closed, so its card still has somewhere to go")
    }

    func test_aWaitingToastInAWindowYouAreNotIn_waitsForYouToArrive() throws {
        var config = GeneralConfig.current
        config.attentionToast = .auto
        config.toastDuration = 0.05
        GeneralConfig.setCurrentForTesting(config)
        let c = makeWindow()
        WindowController.isPresent = { _ in false }

        c.notifyAgentForTesting(tabIndex: 0, message: "needs you")
        drainMainQueue()
        XCTAssertEqual(toastViews(c).count, 1, "precondition: it was raised at all")

        let pastTheDuration = Date().addingTimeInterval(0.4)
        while Date() < pastTheDuration {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(
            toastViews(c).count, 1, "auto means five seconds of your attention, not five of nobody's")
    }

    func test_aPaneInTheActiveTab_isStillSeen() throws {
        let c = makeWindow()

        c.notifyAgentForTesting(tabIndex: 0, message: "needs you")
        drainMainQueue()

        XCTAssertNil(c.attentionStateForTesting(tabIndex: 0), "a pane in the tab you are in is on screen")
        XCTAssertTrue(toastViews(c).isEmpty)
    }

    func test_aPaneInTheActiveTabOfAWindowYouAreNotIn_isNotSeen() throws {
        let c = makeWindow()
        WindowController.isPresent = { _ in false }

        c.notifyAgentForTesting(tabIndex: 0, message: "needs you")
        drainMainQueue()

        XCTAssertEqual(
            c.attentionStateForTesting(tabIndex: 0), .waiting, "on screen is not seen from another window")
        XCTAssertEqual(toastViews(c).count, 1, "the card is there when you arrive")
    }
}
