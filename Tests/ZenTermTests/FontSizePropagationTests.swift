import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

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
        controller.mountAndStart()
        controllers.append(controller)
        return controller
    }

    func test_step_reachesEveryPaneEveryTabAndTheFloat() throws {
        let controller = makeWindow()
        controller.handle(.splitHorizontal)
        controller.handle(.newTab)
        controller.handle(.toggleToolFloat("btop"))

        let surfaces = spawned
        XCTAssertGreaterThanOrEqual(surfaces.count, 4, "expected two panes, a second tab, and a float")

        SessionFontSize.step(by: 3)
        controller.applySessionFontSize()

        for (index, surface) in surfaces.enumerated() {
            XCTAssertEqual(
                surface.lastFontSize, 17,
                "surface \(index) never got the step: the size reached some "
                    + "surfaces and not others")
        }
    }

    func test_step_reachesASecondWindow() {
        let first = makeWindow()
        let second = makeWindow()

        SessionFontSize.step(by: 2)
        for controller in [first, second] { controller.applySessionFontSize() }

        for (index, surface) in spawned.enumerated() {
            XCTAssertEqual(surface.lastFontSize, 16, "surface \(index) in one of the two windows was missed")
        }
    }

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

    func test_floatOpenedAfterAStep_opensAtTheSteppedSize() throws {
        let controller = makeWindow()
        SessionFontSize.step(by: 4)
        controller.applySessionFontSize()

        let before = spawned.count
        controller.handle(.toggleToolFloat("btop"))
        let fresh = try XCTUnwrap(spawned.dropFirst(before).first, "the float spawned no surface")

        XCTAssertEqual(fresh.lastConfig?.fontSize, 18)
    }

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

    func test_fontSizeChords_forwardToTheAppGlobalPath() {
        let controller = makeWindow()
        var forwarded: [KeyInterceptor.ReservedChord] = []
        controller.onAppGlobalCommand = { forwarded.append($0) }

        controller.handle(.increaseFontSize)
        controller.handle(.decreaseFontSize)
        controller.handle(.resetFontSize)

        XCTAssertEqual(forwarded, [.increaseFontSize, .decreaseFontSize, .resetFontSize])
    }

    func test_fontSizeChords_actOverAnOpenFloat() {
        let controller = makeWindow()
        controller.handle(.toggleToolFloat("btop"))
        var forwarded: [KeyInterceptor.ReservedChord] = []
        controller.onAppGlobalCommand = { forwarded.append($0) }

        controller.handle(.increaseFontSize)

        XCTAssertEqual(forwarded, [.increaseFontSize], "the float gate swallowed a font-size chord")
    }
}
