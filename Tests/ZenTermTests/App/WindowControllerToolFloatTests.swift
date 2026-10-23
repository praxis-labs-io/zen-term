import AppKit
import TabKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class WindowControllerToolFloatTests: WindowTestCase {
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
            .appendingPathComponent("zenterm-window-floats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = GeneralConfig.builtIn
        config.floats = [Self.spec("btop", persist: .window), Self.spec("lazygit", persist: .directory)]
        GeneralConfig.setCurrentForTesting(config)
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

    private static func spec(_ id: String, persist: ToolFloat.Persistence) -> ToolFloat {
        ToolFloat(
            id: id, order: 0, title: id, icon: ToolFloatParser.defaultIcon, command: id, dir: nil,
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false, persist: persist,
            toggle: Chord(command: true, shift: true, key: id == "btop" ? "b" : "g"))
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

    private func toastViews(_ c: WindowController) -> [ToastView] {
        guard let content = c.window.contentView else { return [] }
        return descendants(of: content).compactMap { $0 as? ToastView }
    }

    private func floatSurfaces(command: String) -> [RecordingSurface] {
        spawned.filter { $0.lastConfig?.args == ["-l", "-i", "-c", command] }
    }

    func test_windowFloat_isOneInstanceSharedAcrossTabs() {
        let c = makeWindow()

        c.handle(.toggleToolFloat("btop"))
        XCTAssertEqual(floatSurfaces(command: "btop").count, 1)
        c.handle(.toggleToolFloat("btop"))

        c.handle(.newTab)
        c.handle(.toggleToolFloat("btop"))

        let all = floatSurfaces(command: "btop")
        XCTAssertEqual(all.count, 1, "a second tab must reveal the window's instance, not spawn its own")
        XCTAssertEqual(all[0].startCount, 1, "the shared surface must not be restarted")
        XCTAssertFalse(all[0].terminated)
    }

    func test_windowFloat_survivesTheTabItWasOpenedIn() {
        let c = makeWindow()
        c.handle(.newTab)
        c.handle(.toggleToolFloat("btop"))
        c.handle(.toggleToolFloat("btop"))

        c.closeTabForTesting(index: 1)

        let all = floatSurfaces(command: "btop")
        XCTAssertEqual(all.count, 1)
        XCTAssertFalse(all[0].terminated, "a window float outlives the tab it was opened from")
    }

    func test_tabSwitch_dismissesTheFloat() {
        let c = makeWindow()
        c.handle(.newTab)
        c.handle(.toggleToolFloat("btop"))
        XCTAssertEqual(cards(c).count, 1, "the float should be up before the switch")

        c.handle(.prevTab)

        XCTAssertTrue(cards(c).isEmpty, "a tab switch must dismiss the card, not change tabs behind it")
    }

    func test_tabSwitch_dismissesButKeepsAPersistentFloatAlive() {
        let c = makeWindow()
        c.handle(.newTab)
        c.handle(.toggleToolFloat("btop"))
        let surface = floatSurfaces(command: "btop")[0]

        c.handle(.prevTab)
        XCTAssertFalse(surface.terminated, "a persistent float must survive the dismiss")

        c.handle(.toggleToolFloat("btop"))
        let all = floatSurfaces(command: "btop")
        XCTAssertEqual(all.count, 1, "reopening after a tab switch must reuse the window's instance")
        XCTAssertEqual(all[0].startCount, 1, "the shared surface must not be restarted")
    }

    func test_tabBarClicks_dismissTheFloat() {
        let c = makeWindow()
        c.handle(.newTab)
        c.handle(.toggleToolFloat("btop"))

        c.selectTabForTesting(index: 0)

        XCTAssertTrue(cards(c).isEmpty, "clicking a tab chip must dismiss the float too")
    }

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

    func test_floatNotification_isRelayed_evenWhileHidden() {
        let c = makeWindow()
        c.handle(.toggleToolFloat("btop"))
        let surface = floatSurfaces(command: "btop")[0]
        c.handle(.toggleToolFloat("btop"))

        var relayed: [(TerminalNotification, ToolFloat, TabID?)] = []
        c.floatsForTesting.onNotification = { relayed.append(($1, $2, $3)) }
        surface.delegate?.surface(
            surface, didPostNotification: TerminalNotification(title: "Claude", body: "needs input"))

        XCTAssertEqual(relayed.count, 1, "a hidden float's notification must not be dropped")
        XCTAssertEqual(relayed.first?.1.id, "btop", "the banner needs the float it came from to name it")
        XCTAssertNil(relayed.first?.2, "a window float belongs to no tab, so the banner takes the active one")
    }

    func test_windowFloat_neverReanchorsWhenTheFocusedCWDMoves() throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let c = makeWindow()

        c.handle(.toggleToolFloat("btop"))
        let first = floatSurfaces(command: "btop")[0]
        c.handle(.toggleToolFloat("btop"))

        spawned[0].currentDirectory = elsewhere
        c.handle(.toggleToolFloat("btop"))

        XCTAssertFalse(first.terminated, "a window float has no anchor to go stale")
        XCTAssertEqual(floatSurfaces(command: "btop").count, 1, "reopen must reuse, not respawn")
    }

    func test_windowClose_terminatesHiddenFloats() {
        let c = makeWindow()

        c.handle(.toggleToolFloat("btop"))
        let surface = floatSurfaces(command: "btop")[0]
        c.handle(.toggleToolFloat("btop"))
        XCTAssertFalse(surface.terminated)

        c.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil

        XCTAssertTrue(surface.terminated, "a hidden float must not outlive its window")
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

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

    func test_paneChordOverAFloat_saysWhyInsteadOfDoingNothing() throws {
        let c = makeWindow()
        c.handle(.toggleToolFloat("btop"))

        c.handle(.navLeft)

        let toast = try XCTUnwrap(toastViews(c).first, "a swallowed chord must speak")
        let labels = descendants(of: toast).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(
            labels.contains { $0.contains("btop") },
            "the notice must name the float in the way: \(labels)")
    }

    func test_repeatedPaneChordsOverAFloat_coalesceIntoOneNotice() {
        let c = makeWindow()
        c.handle(.toggleToolFloat("btop"))

        c.handle(.navLeft)
        c.handle(.navRight)
        c.handle(.toggleZoom)

        XCTAssertEqual(
            toastViews(c).count, 1,
            "repeats inside the throttle window must coalesce into the one card already up")
    }
}
