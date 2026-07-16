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
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: harness

    private static func spec(_ id: String, persist: ToolFloat.Persistence) -> ToolFloat {
        ToolFloat(
            id: id, title: "Open \(id)", icon: ToolFloatParser.defaultIcon, command: id, dir: nil,
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false, persist: persist,
            toggle: Chord(command: true, shift: true, key: id == "btop" ? "b" : "g"))
    }

    private func makeWindow() -> WindowController {
        let c = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        c.showAndStart()
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

    /// The hazard this ticket is built around: the card hosts on the window's `container`, so
    /// switching tabs beneath an open float leaves it mounted, on screen, and holding focus.
    /// Hosted on the active tab's `content` (the old path), the switch unmounts it — the card
    /// vanishes while the engine still believes it's shown, and every chord stays gated behind an
    /// invisible float.
    func test_shownFloat_survivesATabSwitch() {
        let c = makeWindow()
        c.handle(.newTab)  // two tabs, second active

        c.handle(.toggleToolFloat("btop"))
        guard let card = cards(c).first else { return XCTFail("expected a float card on screen") }
        let surface = floatSurfaces(command: "btop")[0]

        c.handle(.prevTab)  // switch out from under the open card

        XCTAssertEqual(cards(c).count, 1, "the card must still be in the window's view tree")
        XCTAssertNotNil(card.window, "the card must still be on screen, not unmounted with its tab")
        XCTAssertTrue(
            surface.view.isDescendant(of: card),
            "the float's surface must still be hosted in its card after the switch")
        XCTAssertTrue(surface.isFocused, "the float is modal — a tab switch must not steal its focus")
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
}
