import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// ZEN-224 itself: a font-size step has to reach every terminal surface, not the focused one.
///
/// libghostty binds ⌘+ / ⌘- / ⌘0 itself and applies each to the surface that has focus, so the
/// shipped behavior was a size change landing on one pane while its siblings, the other tabs and any
/// open tool float stayed where they were. Every assertion here is about reach, which is exactly the
/// silently-dead class: the focused pane resizes either way, so the bug looks fixed on screen while
/// nothing else moves.
///
/// Reach also runs forward in time. A pane split *after* a step is a surface the fan-out never saw,
/// and if it opens at the config size the panes on screen disagree — the same bug wearing a
/// different hat, which is why the spawn config is asserted here too and not just the live push.
@MainActor
final class FontSizePropagationTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
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
            .appendingPathComponent("zenterm-font-size-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = GeneralConfig.builtIn
        config.fontSize = 14
        config.floats = [Self.spec("btop")]
        GeneralConfig.setCurrentForTesting(config)
        SessionFontSize.seed(from: config)
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        controllers = []
        spawned = []
        Motion.isReduceMotionEnabled = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        SessionFontSize.seed(from: GeneralConfig.builtIn)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private static func spec(_ id: String) -> ToolFloat {
        ToolFloat(
            id: id, order: 0, title: id, icon: ToolFloatParser.defaultIcon, command: id, dir: nil,
            widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false, persist: .window,
            toggle: Chord(command: true, shift: true, key: "b"))
    }

    private func makeWindow() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: root)
        controller.showAndStart()
        controllers.append(controller)
        return controller
    }

    /// The core claim. Two panes, two tabs and a tool float in one window: a step reaches all of
    /// them, and every one of them lands on the same number.
    func test_step_reachesEveryPaneEveryTabAndTheFloat() throws {
        let controller = makeWindow()
        controller.handle(.splitHorizontal)  // second pane
        controller.handle(.newTab)  // second tab, with its own pane
        controller.handle(.toggleToolFloat("btop"))  // and a float surface

        let surfaces = spawned
        XCTAssertGreaterThanOrEqual(surfaces.count, 4, "expected two panes, a second tab, and a float")

        SessionFontSize.step(by: 3)
        controller.applySessionFontSize()

        for (index, surface) in surfaces.enumerated() {
            XCTAssertEqual(
                surface.lastFontSize, 17,
                "surface \(index) never got the step — this is ZEN-224: the size reached some "
                    + "surfaces and not others")
        }
    }

    /// A second window is the same bug one level out. The size is app-global, so it can't be scoped
    /// to whichever window happens to be key when the chord fires.
    func test_step_reachesASecondWindow() {
        let first = makeWindow()
        let second = makeWindow()

        SessionFontSize.step(by: 2)
        for controller in [first, second] { controller.applySessionFontSize() }

        for (index, surface) in spawned.enumerated() {
            XCTAssertEqual(surface.lastFontSize, 16, "surface \(index) in one of the two windows was missed")
        }
    }

    /// Reach forward in time: a pane opened after a step comes up matched, rather than at the config
    /// size beside siblings that have grown.
    func test_paneSplitAfterAStep_opensAtTheSteppedSize() throws {
        let controller = makeWindow()
        SessionFontSize.step(by: 4)
        controller.applySessionFontSize()

        let before = spawned.count
        controller.handle(.splitHorizontal)
        let fresh = try XCTUnwrap(spawned.dropFirst(before).first, "the split spawned no surface")

        XCTAssertEqual(
            fresh.lastConfig?.fontSize, 18,
            "a pane split after a step opened at the config size — the step propagated to the "
                + "surfaces on screen but not to the next one")
    }

    /// Same claim for a tool float, which spawns through its own config builder rather than
    /// `ShellLaunch` and would otherwise miss the seeding independently.
    func test_floatOpenedAfterAStep_opensAtTheSteppedSize() throws {
        let controller = makeWindow()
        SessionFontSize.step(by: 4)
        controller.applySessionFontSize()

        let before = spawned.count
        controller.handle(.toggleToolFloat("btop"))
        let fresh = try XCTUnwrap(spawned.dropFirst(before).first, "the float spawned no surface")

        XCTAssertEqual(fresh.lastConfig?.fontSize, 18)
    }

    /// A theme edit must not quietly undo a step. libghostty stops applying config reloads to a
    /// surface's font once it has an explicit size, so the theme's size wouldn't land on a stepped
    /// surface anyway — but a surface *spawned* at the stepped size has no explicit size and would
    /// follow the theme back down, leaving one tab's panes at two sizes.
    func test_themeReapply_leavesEverySurfaceOnTheSteppedSize() throws {
        let controller = makeWindow()
        controller.handle(.splitHorizontal)
        SessionFontSize.step(by: 3)
        controller.applySessionFontSize()

        NotificationCenter.default.post(
            name: .configDidChange, object: nil,
            userInfo: [ConfigChange.userInfoKey: ConfigChange.theme])

        for (index, surface) in spawned.enumerated() {
            XCTAssertEqual(
                surface.lastFontSize, 17,
                "surface \(index) fell back to the theme's size after a theme edit")
        }
    }

    /// The chords are app-global, like ⌘N and ⌘⌥R: `handle` forwards rather than acting, so the one
    /// window that happens to be key can't resize only itself. Without the forward a palette pick is
    /// silently a no-op, which is how Reload Config used to break.
    func test_fontSizeChords_forwardToTheAppGlobalPath() {
        let controller = makeWindow()
        var forwarded: [KeyInterceptor.ReservedChord] = []
        controller.onAppGlobalCommand = { forwarded.append($0) }

        controller.handle(.increaseFontSize)
        controller.handle(.decreaseFontSize)
        controller.handle(.resetFontSize)

        XCTAssertEqual(forwarded, [.increaseFontSize, .decreaseFontSize, .resetFontSize])
    }

    /// An open tool float swallows pane chords (split, nav, Focus Mode) because they have nowhere to
    /// go. Font size is not one of those: the float is itself a terminal surface, so it resizes with
    /// everything else rather than being blocked.
    func test_fontSizeChords_actOverAnOpenFloat() {
        let controller = makeWindow()
        controller.handle(.toggleToolFloat("btop"))
        var forwarded: [KeyInterceptor.ReservedChord] = []
        controller.onAppGlobalCommand = { forwarded.append($0) }

        controller.handle(.increaseFontSize)

        XCTAssertEqual(forwarded, [.increaseFontSize], "the float gate swallowed a font-size chord")
    }
}
