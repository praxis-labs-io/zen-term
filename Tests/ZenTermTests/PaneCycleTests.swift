import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class PaneCycleTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controllers: [WindowController] = []
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(GeneralConfig.builtIn)
        Motion.isReduceMotionEnabled = { true }
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-pane-cycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for controller in controllers {
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        controllers = []
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Lays out between splits: `split` refuses a pane whose bounds are still zero.
    private func threePanes(_ controller: WindowController) {
        controller.handle(.splitVertical)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        controller.handle(.splitHorizontal)
        controller.window.contentView?.layoutSubtreeIfNeeded()
    }

    private func panelCount(in controller: WindowController) -> Int {
        guard let root = controller.window.contentView else { return 0 }
        return descendants(of: root).compactMap { $0 as? PanelHostView }.count
    }

    private func toastViews(in controller: WindowController) -> [ToastView] {
        guard let root = controller.window.contentView else { return [] }
        return descendants(of: root).compactMap { $0 as? ToastView }
    }

    private func makeWindow() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: root)
        controller.mountAndStart()
        controllers.append(controller)
        return controller
    }

    private func focused(_ controller: WindowController) throws -> ObjectIdentifier {
        ObjectIdentifier(try XCTUnwrap(controller.focusedPanelForTesting))
    }

    private func walk(
        _ controller: WindowController, _ chord: KeyInterceptor.ReservedChord, _ count: Int
    ) throws -> [ObjectIdentifier] {
        var stops: [ObjectIdentifier] = [try focused(controller)]
        for _ in 0..<count {
            controller.handle(chord)
            stops.append(try focused(controller))
        }
        return stops
    }

    func test_nextPaneVisitsEveryPaneAndWrapsToTheStart() throws {
        let controller = makeWindow()
        threePanes(controller)
        XCTAssertEqual(panelCount(in: controller), 3, "precondition: two splits make three panes")

        let stops = try walk(controller, .nextPane, 3)

        XCTAssertEqual(Set(stops.dropLast()).count, 3, "three panes, three distinct stops: \(stops)")
        XCTAssertEqual(stops.first, stops.last, "the third step has to wrap back to where it started")
    }

    func test_prevPaneWalksTheSameRingBackwards() throws {
        let controller = makeWindow()
        threePanes(controller)

        let forward = try walk(controller, .nextPane, 3)
        let backward = try walk(controller, .prevPane, 3)

        XCTAssertEqual(backward, forward.reversed())
    }

    func test_anOpenDrawerJoinsTheRing() throws {
        let controller = makeWindow()
        controller.handle(.splitVertical)
        let panesOnly = Set(try walk(controller, .nextPane, 2).dropLast())
        controller.handle(.toggleBottomDrawer)

        let withDrawer = Set(try walk(controller, .nextPane, 3).dropLast())

        XCTAssertEqual(panesOnly.count, 2)
        XCTAssertEqual(withDrawer.count, 3, "the drawer has to be one of the stops")
        XCTAssertTrue(panesOnly.isSubset(of: withDrawer))
    }

    func test_onePaneCyclesToItselfAndSaysNothing() throws {
        let controller = makeWindow()
        let before = try focused(controller)

        controller.handle(.nextPane)
        controller.handle(.prevPane)

        XCTAssertEqual(try focused(controller), before)
        XCTAssertTrue(toastViews(in: controller).isEmpty, "a single pane is not a problem to report")
    }

    func test_theShippedChordsAreTheShiftedBrackets() {
        XCTAssertEqual(KeymapDefaults.map[Chord(command: true, shift: true, key: "[")], .prevPane)
        XCTAssertEqual(KeymapDefaults.map[Chord(command: true, shift: true, key: "]")], .nextPane)
        XCTAssertEqual(KeymapDefaults.map[Chord(command: true, key: "[")], .prevTab, "⌘[ stays tabs")
        XCTAssertEqual(KeymapDefaults.map[Chord(command: true, key: "]")], .nextTab)
    }

    func test_neitherRepeatsOnAHeldKey() {
        XCTAssertFalse(KeyInterceptor.ReservedChord.prevPane.shouldRepeat)
        XCTAssertFalse(KeyInterceptor.ReservedChord.nextPane.shouldRepeat)
    }
}
