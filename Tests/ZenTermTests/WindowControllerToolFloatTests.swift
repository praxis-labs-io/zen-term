import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// The window-scope claims ZEN-141 exists for, driven through the real chord path on a real
/// window with real tabs.
///
/// `ToolFloatControllerTests` covers the `persist:` lifecycle against the engine's seam; these are
/// the assertions that seam can't make, because they're about the engine being window-level at
/// all: one live instance shared by every tab, and a card hosted on `container` rather than the
/// active tab's `content`, so a tab switch doesn't unmount it. That second one is the whole
/// hazard — a tab-hosted card is exactly why `closeModal()` has to run before any tab-bar op.
@MainActor
final class WindowControllerToolFloatTests: XCTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?
    private var spawned: [RecordingSurface] = []
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        // Reduce Motion runs `animateOut`'s completion synchronously, so a dismissed card is out of
        // the view tree by the time an assertion reads it — otherwise these race the spring and see
        // a card that's on its way out. The animation itself is `MotionTests`' subject, not this
        // suite's; here it's only in the way.
        Motion.isReduceMotionEnabled = { true }
        // The real ghostty backend needs a live libghostty app, which a test bundle has no
        // business spinning up — inject a headless stub surface instead, and record every spawn.
        TerminalSurfaceFactory.makeOverride = { [weak self] in
            let surface = RecordingSurface()
            self?.spawned.append(surface)
            return surface
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-window-floats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Pin the catalog: `handle(.toggleToolFloat)` resolves the spec through `ToolFloatCatalog`,
        // which reads `GeneralConfig.current` — the tester's own config must never decide this.
        var config = GeneralConfig.builtIn
        config.floats = [Self.spec("btop", persist: .window), Self.spec("lazygit", persist: .directory)]
        GeneralConfig.setCurrentForTesting(config)
    }

    override func tearDownWithError() throws {
        // The controller's own teardown (kills surfaces, invalidates the title poll, removes the
        // config observer) runs through its NSWindowDelegate entry point.
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

    private static func spec(_ id: String, persist: ToolFloat.Persistence) -> ToolFloat {
        ToolFloat(
            id: id, order: 0, title: id, icon: ToolFloatParser.defaultIcon, command: id, dir: nil,
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false, persist: persist,
            toggle: Chord(command: true, shift: true, key: id == "btop" ? "b" : "g"))
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        c.showAndStart()
        // Resolve the repo root synchronously so a float opens within the same turn as the toggle
        // chord these tests drive; the off-main default is the diff-viewer/ToolFloat async suites'.
        c.floatsForTesting.resolveRepoRoot = { $1(GitRepo.repoRoot(for: $0)) }
        controller = c
        return c
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    /// The float cards currently live in the window's view tree.
    private func cards(_ c: WindowController) -> [SurfaceFloatOverlay] {
        guard let content = c.window.contentView else { return [] }
        return descendants(of: content).compactMap { $0 as? SurfaceFloatOverlay }
    }

    /// The toasts currently on screen, read from the real view tree the way
    /// `WindowControllerToastSeamTests` does — no production test hook needed.
    private func toastViews(_ c: WindowController) -> [ToastView] {
        guard let content = c.window.contentView else { return [] }
        return descendants(of: content).compactMap { $0 as? ToastView }
    }

    /// The surfaces spawned for one float — filtered by the command its spec launches, so the
    /// tabs' own pane surfaces never count.
    private func floatSurfaces(command: String) -> [RecordingSurface] {
        spawned.filter { $0.lastConfig?.args == ["-l", "-i", "-c", command] }
    }

    // MARK: tests

    /// The registry is the window's, not the tab's: opening the same float from a second tab must
    /// reveal the SAME instance. Per-tab, this spawns a second process — which is exactly the
    /// "two tabs on one repo, two lazygits" duplication ZEN-141 removes.
    func test_windowFloat_isOneInstanceSharedAcrossTabs() {
        let c = makeWindow()

        c.handle(.toggleToolFloat("btop"))
        XCTAssertEqual(floatSurfaces(command: "btop").count, 1)
        c.handle(.toggleToolFloat("btop"))  // dismiss; a persistent float stays alive

        c.handle(.newTab)
        c.handle(.toggleToolFloat("btop"))

        let all = floatSurfaces(command: "btop")
        XCTAssertEqual(all.count, 1, "a second tab must reveal the window's instance, not spawn its own")
        XCTAssertEqual(all[0].startCount, 1, "the shared surface must not be restarted")
        XCTAssertFalse(all[0].terminated)
    }

    /// A float is modal over the window, so the tab underneath must not change behind it — the
    /// same rule every modal card follows (`select` → `closeModal()`). Switching dismisses the
    /// card and reveals the new tab in one keystroke, instead of leaving the user typing into a
    /// card while the world they can't see moved.
    func test_tabSwitch_dismissesTheFloat() {
        let c = makeWindow()
        c.handle(.newTab)  // two tabs, second active
        c.handle(.toggleToolFloat("btop"))
        XCTAssertEqual(cards(c).count, 1, "the float should be up before the switch")

        c.handle(.prevTab)

        XCTAssertTrue(cards(c).isEmpty, "a tab switch must dismiss the card, not change tabs behind it")
    }

    /// Dismissed by a tab switch, but NOT killed: the registry is the window's, so the process
    /// survives and reopening from the tab you landed on is instant and lands on the same
    /// instance. That's the whole point of lifting the registry — without it, this flow would
    /// re-pay btop's startup on every tab change.
    func test_tabSwitch_dismissesButKeepsAPersistentFloatAlive() {
        let c = makeWindow()
        c.handle(.newTab)
        c.handle(.toggleToolFloat("btop"))
        let surface = floatSurfaces(command: "btop")[0]

        c.handle(.prevTab)
        XCTAssertFalse(surface.terminated, "a persistent float must survive the dismiss")

        c.handle(.toggleToolFloat("btop"))  // reopen from the tab we landed on
        let all = floatSurfaces(command: "btop")
        XCTAssertEqual(all.count, 1, "reopening after a tab switch must reuse the window's instance")
        XCTAssertEqual(all[0].startCount, 1, "the shared surface must not be restarted")
    }

    /// The tab bar sits below the card and stays clickable, so a chip click is a second way into
    /// a tab change — it must honor the same rule the chord does. The "+" button deliberately
    /// bypasses `handle(_:)` entirely, which is exactly why this can't be gated there.
    func test_tabBarClicks_dismissTheFloat() {
        let c = makeWindow()
        c.handle(.newTab)
        c.handle(.toggleToolFloat("btop"))

        c.selectTabForTesting(index: 0)  // a tab-bar chip click, not a chord

        XCTAssertTrue(cards(c).isEmpty, "clicking a tab chip must dismiss the float too")
    }

    /// Every tab-changing op must dismiss the float, not just the chord path — a float surviving
    /// into a `mount()` is what leaves the incoming tab's pane halo lit behind a card that holds
    /// first responder (two focus owners, no way to tell where typing lands). Rather than trust
    /// that each op remembers, pin the invariant across all of them.
    func test_everyTabChangingOp_dismissesTheFloat() {
        let c = makeWindow()
        c.handle(.newTab)

        let ops: [(String, () -> Void)] = [
            ("new tab", { c.handle(.newTab) }),
            ("next tab", { c.handle(.nextTab) }),
            ("prev tab", { c.handle(.prevTab) }),
            ("tab-bar click", { c.selectTabForTesting(index: 0) }),
        ]
        for (name, op) in ops {
            c.handle(.toggleToolFloat("btop"))
            XCTAssertFalse(cards(c).isEmpty, "precondition: the float should be up before \(name)")
            op()
            XCTAssertTrue(cards(c).isEmpty, "\(name) must dismiss the float")
        }
    }

    /// A float's agent asking for input must still reach the user (ZEN-139). The float's surface
    /// delegate moved from `TabController` — whose blanket relay every tab-owned surface got for
    /// free — to `ToolFloatController`, so this is the assertion that the relay came with it.
    /// A dismissed `persist:` agent has no on-screen trace at all, which is the case that needs
    /// the banner most.
    func test_floatNotification_isRelayed_evenWhileHidden() {
        let c = makeWindow()
        c.handle(.toggleToolFloat("btop"))
        let surface = floatSurfaces(command: "btop")[0]
        c.handle(.toggleToolFloat("btop"))  // dismissed; still alive in the registry

        var relayed: [(TerminalNotification, ToolFloat)] = []
        c.floatsForTesting.onNotification = { relayed.append(($0, $1)) }
        surface.delegate?.surface(
            surface, didPostNotification: TerminalNotification(title: "Claude", body: "needs input"))

        XCTAssertEqual(relayed.count, 1, "a hidden float's notification must not be dropped")
        XCTAssertEqual(relayed.first?.1.id, "btop", "the banner needs the float it came from to name it")
    }

    /// `persist:window` anchors where it first opened and never re-anchors: it's for tools that
    /// aren't about the directory you're in. This does what forces a respawn for `persist:dir`
    /// (see `ToolFloatControllerTests.test_dirFloat_respawnsWhenAnchorChanges`) and asserts the
    /// window float ignores it.
    func test_windowFloat_neverReanchorsWhenTheFocusedCWDMoves() throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let c = makeWindow()

        c.handle(.toggleToolFloat("btop"))
        let first = floatSurfaces(command: "btop")[0]
        c.handle(.toggleToolFloat("btop"))

        // The focused pane cd'd somewhere else entirely.
        spawned[0].currentDirectory = elsewhere
        c.handle(.toggleToolFloat("btop"))

        XCTAssertFalse(first.terminated, "a window float has no anchor to go stale")
        XCTAssertEqual(floatSurfaces(command: "btop").count, 1, "reopen must reuse, not respawn")
    }

    /// Floats outlive their tab but not their window — closing it must take the hidden ones with
    /// it. They're invisible by definition, so nothing else would ever reap them.
    func test_windowClose_terminatesHiddenFloats() {
        let c = makeWindow()

        c.handle(.toggleToolFloat("btop"))
        let surface = floatSurfaces(command: "btop")[0]
        c.handle(.toggleToolFloat("btop"))  // dismissed, still running
        XCTAssertFalse(surface.terminated)

        c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil  // teardown already ran

        XCTAssertTrue(surface.terminated, "a hidden float must not outlive its window")
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    /// An open float re-reads `background-alpha` (ZEN-287), so the fan-out has to reach it on a
    /// `.terminalBehavior` change and not only a theme swap. This is the silent half: the card
    /// keeps rendering at its old fill, nothing errors, and the setting looks like it did nothing
    /// until the float is closed and reopened. `ConfigChangeTests` owns the alpha → kind mapping;
    /// this is about which fan-out branch the float hangs off.
    func test_alphaChangeReachesAnOpenFloat_withoutAThemeSwap() throws {
        let c = makeWindow()
        c.handle(.toggleToolFloat("btop"))
        let overlay = try XCTUnwrap(cards(c).first, "the float should be up")
        let card = try XCTUnwrap(
            descendants(of: overlay).first(where: { $0 is ShadowCardView }), "expected the card")
        XCTAssertNotNil(card.layer?.backgroundColor, "at alpha 1 the card carries its own fill")

        var config = GeneralConfig.current
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)
        NotificationCenter.default.post(
            name: .configDidChange, object: nil,
            userInfo: [ConfigChange.userInfoKey: ConfigChange.terminalBehavior])
        drainMainQueue()

        XCTAssertNil(
            card.layer?.backgroundColor,
            "the card must drop its fill so the ring and the terminal paint the interior")
    }

    /// A pane command pressed over a float used to do nothing at all: the float is modal, so
    /// `handle` swallows nav/split/resize/drawer/zoom, and the keystroke vanished with no trace
    /// (ZEN-270). It must say why instead.
    ///
    /// The card on screen is the runbook's; what's silently dead here is the ROUTING — a chord
    /// dropped from the case list goes back to failing quietly, and nothing on screen says so.
    func test_paneChordOverAFloat_saysWhyInsteadOfDoingNothing() throws {
        let c = makeWindow()
        // `btop`, not `lazygit`: a `persist: .directory` float opens behind an async repo-root
        // probe, so the card wouldn't be up yet and these would assert against the tab's own
        // "no neighbor" toast instead. `.window` opens synchronously.
        c.handle(.toggleToolFloat("btop"))

        c.handle(.navLeft)

        let toast = try XCTUnwrap(toastViews(c).first, "a swallowed chord must speak")
        // Assert the rendered text, not the content struct: what could still be broken is the card
        // showing something other than what it was handed.
        let labels = descendants(of: toast).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(
            labels.contains { $0.contains("btop") },
            "the notice must name the float in the way: \(labels)")
    }

    /// Held chords auto-repeat, so an unthrottled notice stacks one card per keystroke. This is
    /// the half no one can eyeball: a throttle that never resets looks identical on the first
    /// press and silently swallows every notice thereafter.
    func test_repeatedPaneChordsOverAFloat_coalesceIntoOneNotice() {
        let c = makeWindow()
        // `btop`, not `lazygit`: a `persist: .directory` float opens behind an async repo-root
        // probe, so the card wouldn't be up yet and these would assert against the tab's own
        // "no neighbor" toast instead. `.window` opens synchronously.
        c.handle(.toggleToolFloat("btop"))

        c.handle(.navLeft)
        c.handle(.navRight)  // a different chord, same notice
        c.handle(.toggleZoom)

        XCTAssertEqual(
            toastViews(c).count, 1,
            "repeats inside the throttle window must coalesce into the one card already up")
    }
}
