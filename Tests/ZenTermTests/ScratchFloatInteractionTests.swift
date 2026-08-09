import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// The built-in Scratch float driven through the real chord on a real window (ZEN-379).
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
        Motion.isReduceMotionEnabled = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: harness

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        c.showAndStart()
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

    private func toggleScratch(_ c: WindowController) {
        c.handle(.toggleToolFloat(ToolFloat.scratch.id))
    }

    /// Open Scratch and hand back the surface it spawned. A Scratch shell and a pane's launch the
    /// same way, so nothing in the config tells them apart — the spawn this toggle caused is the
    /// only reliable handle, and asserting it caused exactly one is half the point.
    private func openScratch(_ c: WindowController) -> RecordingSurface {
        let before = spawned.count
        toggleScratch(c)
        XCTAssertEqual(spawned.count, before + 1, "the open must spawn exactly one shell")
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

    /// One instance for the window, shared by every tab — `persist:window`, same as a user float
    /// declaring it. A tab switch dismisses the card but must not kill the shell.
    func test_itIsOneShellForTheWholeWindow() {
        let c = makeWindow()
        let surface = openScratch(c)

        c.handle(.newTab)  // spawns the new tab's pane, and dismisses the card
        XCTAssertFalse(surface.terminated, "a tab change dismisses the card, not the shell")

        let spawnedBefore = spawned.count
        toggleScratch(c)

        XCTAssertEqual(spawned.count, spawnedBefore, "the second tab reveals the window's shell")
        XCTAssertEqual(surface.startCount, 1)
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
