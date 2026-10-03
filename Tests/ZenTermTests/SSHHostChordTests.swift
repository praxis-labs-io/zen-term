import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class SSHHostChordTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private let originalPresence = WindowController.isPresent
    private var controllers: [WindowController] = []
    private var hosts: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
        SidebarController.resetLastChoiceForTesting()
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        WindowController.isPresent = { _ in true }
    }

    override func tearDownWithError() throws {
        for host in hosts.map(SSHHostID.init) {
            SSHHostStatusCenter.shared.setConnected(false, host: host)
            SSHHostStatusCenter.shared.setReachable(false, host: host)
        }
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            AttentionCenter.shared.forget(windowID: controller.windowID)
        }
        controllers = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        WindowController.isPresent = originalPresence
        SidebarController.resetLastChoiceForTesting()
        try super.tearDownWithError()
    }

    private func makeWindow(hosts: [String], offline: [String] = [], connected: [String] = []) -> WindowController {
        self.hosts = hosts
        var config = GeneralConfig.builtIn
        config.sshHosts = hosts
        GeneralConfig.setCurrentForTesting(config)
        for host in hosts where !offline.contains(host) {
            SSHHostStatusCenter.shared.setReachable(true, host: SSHHostID(name: host))
        }
        for host in connected { SSHHostStatusCenter.shared.setConnected(true, host: SSHHostID(name: host)) }
        let c = WindowController(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        controllers.append(c)
        c.mountAndStart()
        c.window.makeKeyAndOrderFront(nil)
        c.window.contentView?.layoutSubtreeIfNeeded()
        return c
    }

    private func row(_ host: String, in c: WindowController) throws -> SettingsNavRow {
        try XCTUnwrap(c.sidebarForTesting.view.hostRowsForTesting.first { $0.titleForTesting == host })
    }

    private func click(_ row: NSView) throws {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: row.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        row.mouseDown(with: event)
    }

    private func selected(_ c: WindowController) -> String? { c.selectedHostForTesting?.name }

    func test_aWorkspaceNumber_reachesAnOnlineHost_pastAnOfflineOne() {
        let c = makeWindow(hosts: ["down", "up"], offline: ["down"])

        c.handle(.selectWorkspace(2))

        XCTAssertEqual(selected(c), "up")
    }

    func test_aConnectedHost_takesANumber() {
        let c = makeWindow(hosts: ["live"], connected: ["live"])

        c.handle(.selectWorkspace(2))

        XCTAssertEqual(selected(c), "live")
    }

    func test_aNumberPastTheLastReachableHost_doesNothing() {
        let c = makeWindow(hosts: ["up", "down"], offline: ["down"])
        let workspace = c.activeWorkspaceIDForTesting

        c.handle(.selectWorkspace(3))

        XCTAssertNil(selected(c))
        XCTAssertEqual(c.activeWorkspaceIDForTesting, workspace)
    }

    func test_nextWorkspace_runsThroughReachableHostsAndWrapsBack() {
        let c = makeWindow(hosts: ["up", "down", "live"], offline: ["down"], connected: ["live"])
        let workspace = c.activeWorkspaceIDForTesting

        c.handle(.nextWorkspace)
        XCTAssertEqual(selected(c), "up")
        c.handle(.nextWorkspace)
        XCTAssertEqual(selected(c), "live", "the offline host is skipped")
        c.handle(.nextWorkspace)
        XCTAssertNil(selected(c))
        XCTAssertEqual(c.activeWorkspaceIDForTesting, workspace)
    }

    func test_previousWorkspace_fromTheWorkspace_landsOnTheLastReachableHost() {
        let c = makeWindow(hosts: ["up", "down"], offline: ["down"])

        c.handle(.prevWorkspace)

        XCTAssertEqual(selected(c), "up")
    }

    func test_fromAnOfflineHost_theCycleStepsToTheNearestReachableRow() throws {
        let c = makeWindow(hosts: ["before", "down", "after"], offline: ["down"])
        let workspace = c.activeWorkspaceIDForTesting

        try click(row("down", in: c))
        XCTAssertEqual(selected(c), "down", "clicking an offline host still opens it")
        c.handle(.nextWorkspace)
        XCTAssertEqual(selected(c), "after")

        try click(row("down", in: c))
        c.handle(.prevWorkspace)
        XCTAssertEqual(selected(c), "before")

        c.handle(.prevWorkspace)
        XCTAssertNil(selected(c))
        XCTAssertEqual(c.activeWorkspaceIDForTesting, workspace)
    }

    private func status(_ host: String, in c: WindowController) throws -> String? {
        try row(host, in: c).accessibilityValue() as? String
    }

    func test_hostRows_sayTheirStatusToVoiceOver_andShowNoStatusText() throws {
        let c = makeWindow(hosts: ["down", "up", "live"], offline: ["down"], connected: ["live"])

        XCTAssertEqual(try status("down", in: c), "Offline")
        XCTAssertEqual(try status("up", in: c), "Online")
        XCTAssertEqual(try status("live", in: c), "Connected")
        XCTAssertEqual(try row("up", in: c).detailForTesting, "")
    }

    func test_hostRows_dotTheirStatusInItsInk() throws {
        let c = makeWindow(hosts: ["down", "up", "live"], offline: ["down"], connected: ["live"])

        XCTAssertEqual(try row("down", in: c).dotColorForTesting, SSHHostStatus.offline.ink.cgColor)
        XCTAssertEqual(try row("up", in: c).dotColorForTesting, SSHHostStatus.online.ink.cgColor)
        XCTAssertEqual(try row("live", in: c).dotColorForTesting, SSHHostStatus.connected.ink.cgColor)
    }

    func test_anOfflineHost_paintsItsTitleLikeAnIdleAgent_andGoingOnlineRepaintsItInPlace() throws {
        let c = makeWindow(hosts: ["devbox"], offline: ["devbox"])
        let offline = try row("devbox", in: c)
        XCTAssertEqual(offline.titleInkForTesting, AttentionTone.idle.ink)

        SSHHostStatusCenter.shared.setReachable(true, host: SSHHostID(name: "devbox"))

        XCTAssertTrue(try row("devbox", in: c) === offline, "the row is repainted, not rebuilt")
        XCTAssertEqual(offline.titleInkForTesting, Theme.current.chrome.foreground.nsColor)
        XCTAssertEqual(offline.dotColorForTesting, SSHHostStatus.online.ink.cgColor)
        XCTAssertEqual(try status("devbox", in: c), "Online")
    }

    func test_aHostConnecting_repaintsItsDotInPlace() throws {
        let c = makeWindow(hosts: ["devbox"])
        let online = try row("devbox", in: c)

        SSHHostStatusCenter.shared.setConnected(true, host: SSHHostID(name: "devbox"))

        XCTAssertTrue(try row("devbox", in: c) === online, "the row is repainted, not rebuilt")
        XCTAssertEqual(online.dotColorForTesting, SSHHostStatus.connected.ink.cgColor)
        XCTAssertEqual(try status("devbox", in: c), "Connected")
    }

    func test_onlyReachableHostRows_offerAWorkspaceShortcut() throws {
        let c = makeWindow(hosts: ["down", "up"], offline: ["down"])

        XCTAssertEqual(try row("up", in: c).tooltip?.label, "Open host")
        XCTAssertEqual(
            try row("up", in: c).tooltip?.shortcutForTesting, CommandCatalog.spec(for: .selectWorkspace(2)).shortcut)
        XCTAssertNil(try row("down", in: c).tooltip?.shortcutForTesting)
    }

    func test_aHostGoingOffline_takesItsNumberAndRedrawsItsRow() throws {
        let c = makeWindow(hosts: ["devbox"])

        SSHHostStatusCenter.shared.setReachable(false, host: SSHHostID(name: "devbox"))

        XCTAssertEqual(try status("devbox", in: c), "Offline")
        XCTAssertNil(try row("devbox", in: c).tooltip?.shortcutForTesting)
        c.handle(.selectWorkspace(2))
        XCTAssertNil(selected(c))
    }

    func test_aStatusChange_keepsKeyboardFocusOnTheHostsRow() throws {
        let c = makeWindow(hosts: ["devbox", "other"])
        XCTAssertTrue(c.sidebarForTesting.focusStop(.host("devbox")))

        SSHHostStatusCenter.shared.setReachable(false, host: SSHHostID(name: "devbox"))

        XCTAssertEqual(c.sidebarForTesting.focusedStop, .host("devbox"))
        XCTAssertTrue(c.window.firstResponder === (try row("devbox", in: c)))
    }

    private func configure(hosts: [String]) {
        var config = GeneralConfig.current
        config.sshHosts = hosts
        GeneralConfig.setCurrentForTesting(config)
        NotificationCenter.default.post(
            name: .configDidChange, object: nil, userInfo: [ConfigChange.userInfoKey: ConfigChange.sshHosts])
        let drained = expectation(description: "main queue")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func test_removingTheSelectedHost_landsOnTheNextHostBelow() throws {
        let c = makeWindow(hosts: ["a", "b", "c"])
        try click(row("b", in: c))

        configure(hosts: ["a", "c"])

        XCTAssertEqual(selected(c), "c")
        XCTAssertEqual(c.window.title, "c")
    }

    func test_removingTheLastSelectedHost_landsOnTheHostAbove_skippingOfflineOnes() throws {
        let c = makeWindow(hosts: ["a", "b", "c", "d"], offline: ["b", "d"])
        try click(row("c", in: c))

        configure(hosts: ["a", "b", "d"])

        XCTAssertEqual(selected(c), "a")
    }

    func test_removingTheOnlyHost_landsOnTheFirstWorkspace() throws {
        let c = makeWindow(hosts: ["devbox"])
        let workspace = c.activeWorkspaceIDForTesting
        try click(row("devbox", in: c))

        configure(hosts: [])

        XCTAssertNil(selected(c))
        XCTAssertEqual(c.activeWorkspaceIDForTesting, workspace)
        XCTAssertNotNil(c.activeTabIDForTesting)
    }

    func test_removingTheSelectedHost_fromSettings_leavesSettingsOpen() throws {
        let c = makeWindow(hosts: ["a", "b"])
        try click(row("a", in: c))
        c.handle(.openSettings)
        XCTAssertTrue(c.isModalOverlayOpen)
        let focused = c.window.firstResponder

        configure(hosts: ["b"])

        XCTAssertEqual(selected(c), "b")
        XCTAssertTrue(c.isModalOverlayOpen)
        XCTAssertTrue(c.window.firstResponder === focused, "Settings keeps the keyboard")
    }

    func test_removingAnotherHost_keepsTheSelection() throws {
        let c = makeWindow(hosts: ["a", "b"])
        try click(row("a", in: c))

        configure(hosts: ["a"])

        XCTAssertEqual(selected(c), "a")
    }

    private final class ModeHostSpy: KeyModeHosting {
        var modeHandler: ((NSEvent) -> Bool)?
    }

    func test_selectingAHost_endsScrollModeAndTakesItsKeysOffTheHiddenPane() throws {
        let c = makeWindow(hosts: ["devbox"])
        let spy = ModeHostSpy()
        c.keyModeHost = spy
        c.handle(.toggleScrollMode)
        XCTAssertTrue(c.scrollMode.isActive)

        try click(row("devbox", in: c))

        XCTAssertFalse(c.scrollMode.isActive)
        XCTAssertNil(spy.modeHandler, "no mode key reaches the hidden terminal")
    }

    func test_selectingAHost_endsSearch() throws {
        let c = makeWindow(hosts: ["devbox"])
        c.handle(.toggleSearch)
        XCTAssertTrue(c.search.isActive)

        try click(row("devbox", in: c))

        XCTAssertFalse(c.search.isActive)
    }

    func test_aNewHost_readsOfflineAndTakesNoNumber_untilItsFirstAnswer() throws {
        let c = makeWindow(hosts: [])
        configure(hosts: ["fresh"])
        hosts = ["fresh"]

        XCTAssertEqual(try status("fresh", in: c), "Offline")
        c.handle(.selectWorkspace(2))
        XCTAssertNil(selected(c), "an unanswered host is not a stop")

        SSHHostStatusCenter.shared.setReachable(true, host: SSHHostID(name: "fresh"))
        c.handle(.selectWorkspace(2))
        XCTAssertEqual(selected(c), "fresh")
    }
}
