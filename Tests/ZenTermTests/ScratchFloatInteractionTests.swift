import AppKit
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class ScratchFloatInteractionTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private var root = FileManager.default.temporaryDirectory

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
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-scratch-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        spawned = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        c.mountAndStart()
        c.floatsForTesting.resolveRepoRoot = { $1(GitRepo.repoRoot(for: $0)) }
        controller = c
        return c
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func cards(_ c: WindowController) -> [SurfaceFloatOverlay] {
        guard let content = c.window.contentView else { return [] }
        return descendants(of: content).compactMap { $0 as? SurfaceFloatOverlay }
    }

    private func toggleScratch(_ c: WindowController) {
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
    }

    private func openScratch(
        _ c: WindowController, file: StaticString = #filePath, line: UInt = #line
    ) -> RecordingSurface {
        let before = spawned.count
        toggleScratch(c)
        XCTAssertEqual(
            spawned.count, before + 1, "the open must spawn exactly one shell", file: file, line: line)
        guard spawned.count > before else { return RecordingSurface() }
        return spawned[before]
    }

    func test_theChordOpensAScratchCard_withNoConfigAtAll() {
        let c = makeWindow()

        _ = openScratch(c)

        XCTAssertEqual(cards(c).count, 1)
    }

    func test_theScratchShell_launchesWithNoCommand() {
        let c = makeWindow()

        let config = openScratch(c).lastConfig

        XCTAssertNil(config?.command, "no configured shell means the backend picks the login shell")
        XCTAssertFalse(config?.args.contains("-c") ?? true, "a scratch shell runs no command")
    }

    func test_aConfiguredShell_isHonoredTheWayAPanesIs() {
        var config = GeneralConfig.builtIn
        config.shell = "/bin/fish"
        GeneralConfig.setCurrentForTesting(config)
        let c = makeWindow()

        let launched = openScratch(c).lastConfig

        XCTAssertEqual(launched?.command, "/bin/fish")
        XCTAssertEqual(launched?.args, ["-l", "-i"])
    }

    func test_theScratchShell_carriesNoNavEnvironment() {
        let c = makeWindow()

        let environment = openScratch(c).lastConfig?.environment ?? [:]

        XCTAssertNil(environment["ZEN_PANE"], "a pane gets one; the float has no panel to route to")
    }

    func test_hidingAndReopening_keepsTheSameShell() {
        let c = makeWindow()
        let surface = openScratch(c)

        toggleScratch(c)
        XCTAssertTrue(cards(c).isEmpty, "the chord hides the card")
        XCTAssertFalse(surface.terminated, "and leaves the shell running")

        let spawnedBefore = spawned.count
        toggleScratch(c)

        XCTAssertEqual(spawned.count, spawnedBefore, "reopening must not spawn a second shell")
        XCTAssertEqual(surface.startCount, 1, "nor restart the one it has")
    }

    func test_theShellExiting_closesTheCard_andTheNextOpenRespawns() {
        let c = makeWindow()
        let surface = openScratch(c)

        surface.delegate?.surfaceDidExit(surface, code: 0)
        XCTAssertTrue(cards(c).isEmpty, "the card goes with the shell")

        XCTAssertFalse(openScratch(c) === surface)
    }

    func test_aTabChangeDismissesTheCard_notTheShell() {
        let c = makeWindow()
        let surface = openScratch(c)

        c.handle(.newTab)

        XCTAssertTrue(cards(c).isEmpty)
        XCTAssertFalse(surface.terminated, "a tab change dismisses the card, not the shell")
        XCTAssertEqual(surface.startCount, 1)
    }

    func test_eachTabGetsItsOwnScratchShell() {
        let c = makeWindow()
        let first = openScratch(c)

        c.handle(.newTab)
        let second = openScratch(c)

        XCTAssertFalse(second === first, "the second tab must not inherit the first tab's shell")
        XCTAssertFalse(first.terminated, "and must not take the first tab's shell down to get one")
    }

    func test_returningToATab_revealsThatTabsOwnShell() {
        let c = makeWindow()
        let first = openScratch(c)
        c.handle(.newTab)
        let second = openScratch(c)

        c.handle(.prevTab)
        let spawnedBefore = spawned.count
        toggleScratch(c)

        XCTAssertEqual(spawned.count, spawnedBefore, "the tab's own shell is still alive")
        guard let card = cards(c).first else { return XCTFail("no card") }
        let shown = descendants(of: card)
        XCTAssertTrue(shown.contains(first.view), "the first tab's card shows the first tab's shell")
        XCTAssertFalse(shown.contains(second.view), "never the other tab's")
    }

    func test_closingATabKillsThatTabsScratchShell() {
        let c = makeWindow()
        c.handle(.newTab)
        let surface = openScratch(c)
        toggleScratch(c)

        c.closeTabForTesting(index: 1)

        XCTAssertTrue(surface.terminated, "a closed tab must not leak its scratch shell")
    }

    func test_closingATabLeavesTheOtherTabsScratchAlone() {
        let c = makeWindow()
        let first = openScratch(c)
        c.handle(.newTab)
        let second = openScratch(c)
        toggleScratch(c)

        c.closeTabForTesting(index: 1)

        XCTAssertTrue(second.terminated)
        XCTAssertFalse(first.terminated, "the surviving tab keeps its own shell")
    }

    func test_closingTheLastPaneOfATab_confirmsWhenItsScratchIsBusy() {
        let c = makeWindow()
        c.handle(.newTab)
        let surface = openScratch(c)
        toggleScratch(c)
        surface.isBusy = true

        c.handle(.closePane)

        XCTAssertTrue(c.isConfirmOpen, "a busy scratch must not be closed out from under the user")
        XCTAssertFalse(surface.terminated, "and nothing dies before the answer")
        XCTAssertTrue(
            toastTexts(in: c).contains { $0.contains("Close Tab") },
            "the confirm names the real effect: \(toastTexts(in: c))")
    }

    func test_theDockDotsScratchOnlyInTheTabItIsRunningIn() {
        let c = makeWindow()
        _ = openScratch(c)
        toggleScratch(c)
        XCTAssertTrue(c.floatsForTesting.isLiveInBackground(ToolFloat.scratch.id))

        c.handle(.newTab)

        XCTAssertFalse(
            c.floatsForTesting.isLiveInBackground(ToolFloat.scratch.id),
            "a tab with no scratch running must not dot one")
    }

    func test_scratchBusy_isAnsweredOnlyInTheTabItIsRunningIn() {
        let c = makeWindow()
        let surface = openScratch(c)
        toggleScratch(c)
        XCTAssertFalse(
            c.floatsForTesting.isBusy(ToolFloat.scratch.id), "dismissed at a prompt is not busy")

        surface.isBusy = true
        XCTAssertTrue(c.floatsForTesting.isBusy(ToolFloat.scratch.id))

        c.handle(.newTab)

        XCTAssertFalse(
            c.floatsForTesting.isBusy(ToolFloat.scratch.id),
            "a tab with no scratch running must not get its button back")
    }

    func test_hidingScratchWhileItWorks_keepsItsButtonThroughTheFanOut() throws {
        let c = makeWindow()
        let dock = try XCTUnwrap(
            descendants(of: c.window.contentView!).compactMap { $0 as? ToggleDock }.first)
        let surface = openScratch(c)
        toggleScratch(c)
        surface.isBusy = true

        var config = GeneralConfig.builtIn
        config.hiddenToolbarButtons = [.scratch]
        GeneralConfig.setCurrentForTesting(config)
        NotificationCenter.default.post(
            name: .configDidChange, object: nil,
            userInfo: [ConfigChange.userInfoKey: ConfigChange.toolbarButtons])
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)

        XCTAssertTrue(
            dock.visibleLayoutForTesting.contains("Scratch"),
            "hiding it mid-job left a running shell with no handle: \(dock.visibleLayoutForTesting)")
    }

    func test_aBackgroundTabsScratchNotification_carriesItsOwnTab() {
        let c = makeWindow()
        let owner = c.activeTabIDForTesting
        let surface = openScratch(c)
        toggleScratch(c)
        c.handle(.newTab)
        XCTAssertNotEqual(c.activeTabIDForTesting, owner)

        var relayed: [(ToolFloat, TabID?)] = []
        c.floatsForTesting.onNotification = { relayed.append(($2, $3)) }
        surface.delegate?.surface(
            surface, didPostNotification: TerminalNotification(title: "Claude", body: "needs input"))

        XCTAssertEqual(relayed.count, 1, "a hidden float's notification must not be dropped")
        XCTAssertEqual(relayed.first?.1, owner, "the banner routes to the tab the shell is in")
    }

    func test_closePaneWhileScratchIsOpen_saysSoRatherThanClosing() {
        let c = makeWindow()
        toggleScratch(c)

        c.handle(.closePane)

        XCTAssertEqual(cards(c).count, 1, "⌘W must not reach the pane behind the card")
        let labels = toastTexts(in: c)
        XCTAssertTrue(
            labels.contains { $0.contains("Scratch") },
            "the notice has to name the thing to close first: \(labels)")
    }
}
