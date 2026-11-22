import AppKit
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class AgentBannerClearingTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private var requests: [AgentNotifier.Request] = []
    private let originalPresence = WindowController.isPresent

    private static let noticeModes: [(name: String, config: GeneralConfig)] = [
        ("off", .builtIn), ("sticky", .builtInWithStickyCards),
    ]

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
        WindowController.isPresent = { _ in true }
        AgentNotifier.shared.recordForTesting = { [weak self] in self?.requests.append($0) }
    }

    override func tearDownWithError() throws {
        closeWindow()
        AgentNotifier.shared.recordForTesting = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        try super.tearDownWithError()
    }

    private func forEachNoticeMode(_ body: (String) throws -> Void) rethrows {
        for mode in Self.noticeModes {
            GeneralConfig.setCurrentForTesting(mode.config)
            try body(mode.name)
            closeWindow()
        }
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        c.mountAndStart()
        controller = c
        c.window.contentView?.layoutSubtreeIfNeeded()
        return c
    }

    private func closeWindow() {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.map { AttentionCenter.shared.forget(windowID: $0.windowID) }
        controller = nil
        spawned = []
        requests = []
    }

    private func drainMainQueue() {
        let expectation = expectation(description: "main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    private func closedRightDrawer(_ c: WindowController) throws -> RecordingSurface {
        let before = spawned.count
        c.handle(.toggleRightDrawer)
        let drawer = try XCTUnwrap(spawned.dropFirst(before).first, "opening the drawer spawns its surface")
        c.handle(.toggleRightDrawer)
        drainMainQueue()
        return drawer
    }

    private func ask(_ surface: RecordingSurface) {
        post(surface, body: AgentNotificationFixtures.claudePermission)
    }

    private func post(_ surface: RecordingSurface, body: String) {
        surface.delegate?.surface(
            surface,
            didPostNotification: TerminalNotification(title: AgentNotificationFixtures.claudeTitle, body: body))
        drainMainQueue()
    }

    private func progress(_ surface: RecordingSurface, _ state: TerminalProgress?) {
        surface.delegate?.surface(surface, progressDidChange: state)
        drainMainQueue()
    }

    private func bannerPosted(_ c: WindowController, tab: TabID) -> Bool {
        requests.contains(.notify(windowID: c.windowID, tabID: tab))
    }

    private func bannerCleared(_ c: WindowController, tab: TabID) -> Bool {
        requests.contains(.clear(windowID: c.windowID, tabID: tab))
    }

    func test_visitingABackgroundTab_clearsItsBanner() throws {
        try forEachNoticeMode { mode in
            let c = makeWindow()
            let agent = try XCTUnwrap(spawned.last)
            c.newTabForTesting()
            drainMainQueue()
            let tab = try XCTUnwrap(c.tabOrderForTesting.first)
            ask(agent)
            XCTAssertTrue(bannerPosted(c, tab: tab), "\(mode): precondition")
            XCTAssertFalse(bannerCleared(c, tab: tab), "\(mode): a banner for a tab you have not seen stays")

            c.selectTab(tab)
            drainMainQueue()

            XCTAssertTrue(bannerCleared(c, tab: tab), "\(mode)")
        }
    }

    func test_visitingATabWithAClosedDrawerAsking_leavesItsBanner_untilTheDrawerOpens() throws {
        try forEachNoticeMode { mode in
            let c = makeWindow()
            let drawer = try closedRightDrawer(c)
            c.newTabForTesting()
            drainMainQueue()
            let tab = try XCTUnwrap(c.tabOrderForTesting.first)
            ask(drawer)
            XCTAssertTrue(bannerPosted(c, tab: tab), "\(mode): precondition")

            c.selectTab(tab)
            drainMainQueue()
            XCTAssertFalse(bannerCleared(c, tab: tab), "\(mode): the drawer that asked is still closed")

            c.handle(.toggleRightDrawer)
            drainMainQueue()
            XCTAssertTrue(bannerCleared(c, tab: tab), "\(mode)")
        }
    }

    func test_aTurnEndAfterAClosedDrawersAsk_leavesTheBannerWithTheDrawer() throws {
        try forEachNoticeMode { mode in
            let c = makeWindow()
            let agent = try XCTUnwrap(spawned.last)
            c.identifyAgentForTesting(try XCTUnwrap(c.focusedSurfaceIDForTesting), name: "claude")
            let drawer = try closedRightDrawer(c)
            c.newTabForTesting()
            drainMainQueue()
            let tab = try XCTUnwrap(c.tabOrderForTesting.first)
            ask(drawer)
            progress(agent, TerminalProgress(state: .indeterminate, fraction: nil))
            progress(agent, nil)

            c.selectTab(tab)
            drainMainQueue()
            XCTAssertFalse(bannerCleared(c, tab: tab), "\(mode): the drawer's ask outranks the turn end")

            c.handle(.toggleRightDrawer)
            drainMainQueue()
            XCTAssertTrue(bannerCleared(c, tab: tab), "\(mode)")
        }
    }

    func test_underAuto_aDrawersBanner_outlivesItsTimedOutCard_untilTheDrawerOpens() throws {
        var config = GeneralConfig.builtIn
        config.attentionToast = .auto
        config.toastDuration = 0.05
        GeneralConfig.setCurrentForTesting(config)
        let c = makeWindow()
        let drawer = try closedRightDrawer(c)
        c.newTabForTesting()
        drainMainQueue()
        let tab = try XCTUnwrap(c.tabOrderForTesting.first)
        ask(drawer)
        XCTAssertNotNil(c.waitingToastForTesting(tab: tab), "precondition: the ask raised its card")
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        XCTAssertNil(c.waitingToastForTesting(tab: tab), "precondition: and it cleared itself")

        c.selectTab(tab)
        drainMainQueue()
        XCTAssertFalse(bannerCleared(c, tab: tab), "the drawer that asked is still closed")

        c.handle(.toggleRightDrawer)
        drainMainQueue()
        XCTAssertTrue(bannerCleared(c, tab: tab), "opening the drawer clears the banner its timed-out card left")
    }

    func test_comingBackToAPaneInView_clearsItsBanner() throws {
        try forEachNoticeMode { mode in
            let c = makeWindow()
            let agent = try XCTUnwrap(spawned.last)
            let tab = try XCTUnwrap(c.tabOrderForTesting.first)
            WindowController.isPresent = { _ in false }
            ask(agent)
            XCTAssertTrue(bannerPosted(c, tab: tab), "\(mode): precondition")
            XCTAssertFalse(bannerCleared(c, tab: tab), "\(mode): precondition")

            WindowController.isPresent = { _ in true }
            c.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

            XCTAssertTrue(bannerCleared(c, tab: tab), "\(mode)")
        }
    }

    func test_aNewTurn_clearsTheBannerOfATurnEndYouMissed() throws {
        try forEachNoticeMode { mode in
            let c = makeWindow()
            let agent = try XCTUnwrap(spawned.last)
            let pane = try XCTUnwrap(c.focusedSurfaceIDForTesting)
            c.identifyAgentForTesting(pane, name: "claude")
            c.newTabForTesting()
            drainMainQueue()
            let tab = try XCTUnwrap(c.tabOrderForTesting.first)
            progress(agent, TerminalProgress(state: .indeterminate, fraction: nil))
            progress(agent, nil)
            post(agent, body: AgentNotificationFixtures.claudeIdlePrompt)
            XCTAssertTrue(bannerPosted(c, tab: tab), "\(mode): precondition: the idle prompt banners a missed turn end")

            progress(agent, TerminalProgress(state: .indeterminate, fraction: nil))

            XCTAssertTrue(bannerCleared(c, tab: tab), "\(mode): a banner for a turn that moved on is stale")
        }
    }
}
