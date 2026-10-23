import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class AttentionCenterWindowTests: WindowTestCase {
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
        controller.map { AttentionCenter.shared.forget(windowID: $0.windowID) }
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

    private func isListed(_ c: WindowController) -> Bool {
        AttentionCenter.shared.waiting.contains { $0.windowID == c.windowID }
    }

    private func waitingCount(_ c: WindowController) -> Int {
        AttentionCenter.shared.waiting.first { $0.windowID == c.windowID }?.count ?? 0
    }

    func test_visitingATabFocusedOnItsDrawer_takesTheWindowOffTheList() {
        let c = makeWindow()
        c.handle(.toggleRightDrawer)
        c.newTabForTesting()
        c.notifyAgentForTesting(tabIndex: 0, message: "needs you")
        drainMainQueue()
        XCTAssertTrue(isListed(c))

        c.selectTabForTesting(index: 0)
        drainMainQueue()

        XCTAssertFalse(isListed(c))
    }

    func test_closingTheTabThatAsked_intoATabFocusedOnItsDrawer_takesTheWindowOffTheList() {
        let c = makeWindow()
        c.newTabForTesting()
        c.handle(.toggleRightDrawer)
        c.notifyAgentForTesting(tabIndex: 0, message: "needs you")
        drainMainQueue()
        XCTAssertEqual(waitingCount(c), 1)

        c.closeTabForTesting(index: 0)
        drainMainQueue()

        XCTAssertEqual(waitingCount(c), 0)
    }

    func test_closingAWindowWithAClosedDrawerAsking_leavesItOffTheList() throws {
        let c = makeWindow()
        let before = spawned.count
        c.handle(.toggleRightDrawer)
        let drawer = try XCTUnwrap(spawned.dropFirst(before).first)
        c.handle(.toggleRightDrawer)
        drawer.delegate?.surface(
            drawer,
            didPostNotification: TerminalNotification(title: "Claude Code", body: "Claude needs your permission"))
        drainMainQueue()
        XCTAssertTrue(isListed(c))

        c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        drainMainQueue()

        XCTAssertFalse(isListed(c))
    }
}
