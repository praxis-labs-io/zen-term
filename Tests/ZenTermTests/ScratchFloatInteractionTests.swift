import AppKit
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// The built-in Scratch float driven through the real chord on a real window.
///
/// `ToolFloatControllerTests` already covers `persist:window` against the engine's seam, so these
/// assert only what is specific to the built-in: that it reaches the engine at all with an empty
/// config, and that it launches a shell rather than a command. The launch config is the one that
/// matters most — every other float goes through `-c <command>`, and a Scratch that quietly took
/// that path would look identical on screen until the user's `shell-args` were ignored.
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
        // Reduce Motion completes `animateOut` synchronously, so a dismissed card is out of the
        // view tree by the time an assertion reads it.
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-scratch-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The empty config is the point: the built-in has to be reachable without one.
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

    // MARK: harness

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

    /// The rendered text of every toast on screen. Read off the real labels, not the content
    /// struct: what could still be broken is a card showing something other than what it was
    /// handed.
    private func toastText(_ c: WindowController) -> [String] {
        guard let content = c.window.contentView else { return [] }
        return descendants(of: content).compactMap { $0 as? ToastView }
            .flatMap { descendants(of: $0).compactMap { ($0 as? NSTextField)?.stringValue } }
    }

    /// A plain workspace for the ⇧⏎ replace path: no recipe, so nothing but the replace itself
    /// is under test.
    private func elsewhere() -> Workspace {
        Workspace(
            title: "Elsewhere", path: root, main: nil, right: nil, bottom: nil, focus: .main,
            env: [:])
    }

    private func toggleScratch(_ c: WindowController) {
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
    }

    /// Open Scratch and hand back the surface it spawned. A Scratch shell and a pane's launch the
    /// same way, so nothing in the config tells them apart — the spawn this toggle caused is the
    /// only reliable handle, and asserting it caused exactly one is half the point.
    private func openScratch(
        _ c: WindowController, file: StaticString = #filePath, line: UInt = #line
    ) -> RecordingSurface {
        let before = spawned.count
        toggleScratch(c)
        XCTAssertEqual(
            spawned.count, before + 1, "the open must spawn exactly one shell", file: file, line: line)
        // A stand-in rather than `spawned[before]` when the spawn didn't happen: indexing traps,
        // and a trap here takes the whole suite down with it — the rest of a failing test reads
        // false, which is what a reader needs to see.
        guard spawned.count > before else { return RecordingSurface() }
        return spawned[before]
    }

    // MARK: tests

    func test_theChordOpensAScratchCard_withNoConfigAtAll() {
        let c = makeWindow()

        _ = openScratch(c)

        XCTAssertEqual(cards(c).count, 1)
    }

    /// The launch config, which is the whole reason `spawn` branches. Every other float runs
    /// `$SHELL -l -i -c <command>`; this one takes a pane's launch, so the backend rewrites argv[0]
    /// to a login shell and the user's `shell-args` are honored.
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

    /// No nav token: the engine has no `PanelRef` to gate a route on, and directional nav is
    /// blocked while a card is up, so there is nowhere for the protocol to hop. Pinned so a later
    /// "make it exactly like a drawer" change has to argue with a test.
    func test_theScratchShell_carriesNoNavEnvironment() {
        let c = makeWindow()

        let environment = openScratch(c).lastConfig?.environment ?? [:]

        XCTAssertNil(environment["ZEN_PANE"], "a pane gets one; the float has no panel to route to")
    }

    /// The drawer behavior the float was asked for: the chord hides the card and leaves the shell
    /// running, and the next press returns the same one.
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

    /// The other half: `exit` really kills it, and the next open is cold rather than resurrecting
    /// a dead surface.
    func test_theShellExiting_closesTheCard_andTheNextOpenRespawns() {
        let c = makeWindow()
        let surface = openScratch(c)

        surface.delegate?.surfaceDidExit(surface, code: 0)
        XCTAssertTrue(cards(c).isEmpty, "the card goes with the shell")

        // `openScratch` asserts the spawn, which is the claim: cold, not resurrected.
        XCTAssertFalse(openScratch(c) === surface)
    }

    /// A tab change dismisses the card and must leave the shell behind it running — the half of
    /// the old window-wide contract that survives `scope: .tab`.
    func test_aTabChangeDismissesTheCard_notTheShell() {
        let c = makeWindow()
        let surface = openScratch(c)

        c.handle(.newTab)  // spawns the new tab's pane, and dismisses the card

        XCTAssertTrue(cards(c).isEmpty)
        XCTAssertFalse(surface.terminated, "a tab change dismisses the card, not the shell")
        XCTAssertEqual(surface.startCount, 1)
    }

    /// The point of `scope: .tab`: a second tab gets its own scratch shell, the way it gets its own
    /// drawers. `openScratch` asserts the spawn, which IS the claim.
    func test_eachTabGetsItsOwnScratchShell() {
        let c = makeWindow()
        let first = openScratch(c)

        c.handle(.newTab)
        let second = openScratch(c)

        XCTAssertFalse(second === first, "the second tab must not inherit the first tab's shell")
        XCTAssertFalse(first.terminated, "and must not take the first tab's shell down to get one")
    }

    /// Going back reveals that tab's own shell, not the one the other tab is running. Reads the
    /// card's view tree rather than the registry: what could break is a card showing the wrong
    /// surface while the bookkeeping looks right.
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

    /// A tab's scratch is the tab's, so closing the tab stops it — the same rule as its drawers.
    func test_closingATabKillsThatTabsScratchShell() {
        let c = makeWindow()
        c.handle(.newTab)
        let surface = openScratch(c)
        toggleScratch(c)  // dismissed but alive: the case with no on-screen trace

        c.closeTabForTesting(index: 1)

        XCTAssertTrue(surface.terminated, "a closed tab must not leak its scratch shell")
    }

    /// The other side of that: an over-broad teardown that took the whole registry with it would
    /// pass the test above and silently kill every other tab's shell.
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

    /// ⌘W on the last pane IS a tab close, so a busy scratch has to be weighed the way a busy
    /// drawer is. Two tabs, so the window-close term can't be what answers, and the card is
    /// dismissed first so the float-modal notice isn't either.
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
            toastText(c).contains { $0.contains("Close Tab") },
            "the confirm names the real effect: \(toastText(c))")
    }

    /// The dock dots a dismissed-but-running float. A tab-scoped one dots only where it runs.
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

    /// What surfaces a hidden Scratch button, and it is tab-scoped the way the dot is. Read through
    /// the wrong registry key it answers false forever, and the button just never appears.
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

    /// A hidden scratch asking for input is usually not in the tab that happens to be up, and the
    /// banner's click has to land where the prompt is. The engine reports the owning tab because it
    /// is the only thing that knows it — the window would otherwise guess the active one, which is
    /// wrong exactly when the notification matters most.
    func test_aBackgroundTabsScratchNotification_carriesItsOwnTab() {
        let c = makeWindow()
        let owner = c.activeTabIDForTesting
        let surface = openScratch(c)
        toggleScratch(c)
        c.handle(.newTab)  // the scratch is now in a background tab
        XCTAssertNotEqual(c.activeTabIDForTesting, owner)

        var relayed: [(ToolFloat, TabID?)] = []
        c.floatsForTesting.onNotification = { relayed.append(($1, $2)) }
        surface.delegate?.surface(
            surface, didPostNotification: TerminalNotification(title: "Claude", body: "needs input"))

        XCTAssertEqual(relayed.count, 1, "a hidden float's notification must not be dropped")
        XCTAssertEqual(relayed.first?.1, owner, "the banner routes to the tab the shell is in")
    }

    /// ⇧⏎ replaces a tab in place, keeping its id. Without a scope teardown the replacement session
    /// inherits the old one's scratch shell — same cwd, same scrollback, from a session that is gone.
    func test_replacingATab_doesNotHandTheNewSessionTheOldScratch() {
        let c = makeWindow()
        let surface = openScratch(c)
        toggleScratch(c)

        c.openWorkspaceForTesting(elsewhere(), replaceCurrentTab: true)

        XCTAssertTrue(surface.terminated, "the replaced session's scratch goes with it")
        XCTAssertFalse(openScratch(c) === surface, "and the new session gets a cold one")
    }

    /// The confirm on that path, which weighs the tab's live work. The scratch is part of the tab
    /// now, so a busy one has to stop the silent clobber.
    func test_replacingABusyTab_confirmsBeforeItStopsTheScratch() {
        let c = makeWindow()
        let surface = openScratch(c)
        toggleScratch(c)
        surface.isBusy = true

        c.openWorkspaceForTesting(elsewhere(), replaceCurrentTab: true)

        XCTAssertTrue(c.isConfirmOpen)
        XCTAssertFalse(surface.terminated, "nothing dies before the answer")
    }

    /// ⌘W over a float is a notice, not a close — the built-in follows the same rule as every
    /// other float rather than the drawer's ⌘W-kills.
    func test_closePaneWhileScratchIsOpen_saysSoRatherThanClosing() {
        let c = makeWindow()
        toggleScratch(c)

        c.handle(.closePane)

        XCTAssertEqual(cards(c).count, 1, "⌘W must not reach the pane behind the card")
        let labels = toastText(c)
        XCTAssertTrue(
            labels.contains { $0.contains("Scratch") },
            "the notice has to name the thing to close first: \(labels)")
    }
}
