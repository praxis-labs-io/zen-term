import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Stepping focus through a tab's panels with ⌘⇧[ and ⌘⇧].
///
/// Driven through a real window with real panes, and asserted on the panel that actually holds
/// focus rather than on the tree's bookkeeping. A cycle that updates `focusedLeaf` while the halo
/// and the keyboard stay where they were is the failure this exists to catch, and only the live
/// panel can tell the two apart.
@MainActor
final class PaneCycleTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var originalReduceMotion: (() -> Bool)!
    private var controllers: [WindowController] = []
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalOverride = TerminalSurfaceFactory.makeOverride
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(GeneralConfig.builtIn)
        // Captured rather than restored to the system reading: a case that pins Reduce Motion for
        // its own reasons must get its value back, or this file decides the suite's order.
        originalReduceMotion = Motion.isReduceMotionEnabled
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
        Motion.isReduceMotionEnabled = originalReduceMotion
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Split twice, with a layout pass between. `split` refuses a pane it measures as too small to
    /// halve, and a freshly rendered pane's bounds are zero until AppKit lays out, so back-to-back
    /// splits in a test silently produce two panes instead of three.
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
        controller.showAndStart()
        controllers.append(controller)
        return controller
    }

    /// The panel holding focus right now, by identity. `ObjectIdentifier` rather than the view
    /// itself so a sequence of them compares and prints readably.
    private func focused(_ controller: WindowController) throws -> ObjectIdentifier {
        ObjectIdentifier(try XCTUnwrap(controller.focusedPanelForTesting))
    }

    /// Walk `count` steps and collect the panel at each stop, starting from where focus is now.
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

    // MARK: three panes

    func test_nextPaneVisitsEveryPaneAndWrapsToTheStart() throws {
        let controller = makeWindow()
        threePanes(controller)
        XCTAssertEqual(panelCount(in: controller), 3, "precondition: two splits make three panes")

        let stops = try walk(controller, .nextPane, 3)

        XCTAssertEqual(Set(stops.dropLast()).count, 3, "three panes, three distinct stops: \(stops)")
        XCTAssertEqual(stops.first, stops.last, "the third step has to wrap back to where it started")
    }

    /// The mirror, and the reason it is its own case: a sign slip cycles forward both ways, which
    /// looks correct in every assertion about distinctness.
    ///
    /// A full backward lap also crosses the front of the ring, which is the end nobody writes by
    /// hand: `(i - 1) % n` is negative in Swift, so an unguarded modulo traps there rather than
    /// landing on the last panel. Three panes is the smallest ring that can tell the two directions
    /// apart at all, since with two every step is both.
    func test_prevPaneWalksTheSameRingBackwards() throws {
        let controller = makeWindow()
        threePanes(controller)

        let forward = try walk(controller, .nextPane, 3)
        let backward = try walk(controller, .prevPane, 3)

        XCTAssertEqual(backward, forward.reversed())
    }

    // MARK: the panels that are not canvas panes

    /// An open drawer is in the ring. Left out, focus could cycle out of a drawer and never back
    /// in, which is worse than not cycling at all.
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

    /// One panel means nowhere to go. Silently, the way `cycleTab` is for one tab: the whole tab is
    /// on screen, so there is nothing a toast could tell you that you cannot see.
    func test_onePaneCyclesToItselfAndSaysNothing() throws {
        let controller = makeWindow()
        let before = try focused(controller)

        controller.handle(.nextPane)
        controller.handle(.prevPane)

        XCTAssertEqual(try focused(controller), before)
        XCTAssertTrue(toastViews(in: controller).isEmpty, "a single pane is not a problem to report")
    }

    // MARK: the chord, and the surfaces that name it

    func test_theShippedChordsAreTheShiftedBrackets() {
        XCTAssertEqual(KeymapDefaults.map[Chord(command: true, shift: true, key: "[")], .prevPane)
        XCTAssertEqual(KeymapDefaults.map[Chord(command: true, shift: true, key: "]")], .nextPane)
        XCTAssertEqual(KeymapDefaults.map[Chord(command: true, key: "[")], .prevTab, "⌘[ stays tabs")
        XCTAssertEqual(KeymapDefaults.map[Chord(command: true, key: "]")], .nextTab)
    }

    /// Both wrap, so holding one never lands anywhere the user aimed — the reason tab cycling
    /// declines key repeat, and the same one here.
    func test_neitherRepeatsOnAHeldKey() {
        XCTAssertFalse(KeyInterceptor.ReservedChord.prevPane.shouldRepeat)
        XCTAssertFalse(KeyInterceptor.ReservedChord.nextPane.shouldRepeat)
    }
}
