import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// `pane-gap` has to reach a split that is already on screen.
///
/// A `SplitContainerView` bakes its gutter in at construction, so unlike every other Layout knob
/// the split gap silently needed a relaunch: `reapplyChromeLayout()` rebuilt the canvas↔drawer
/// constraints (which do carry `panelGap`) and never touched the pane canvas, so the seam beside
/// the panes moved while the gap between them did not.
///
/// This is the narrow exception to "layout is the runbook's, not a test's": the question isn't
/// where a view sits, it's whether a config value reaches the constraint at all — the silently-dead
/// class. It measures the real gap between the two mounted pane hosts rather than a stored field,
/// so it stays honest about what's on screen.
@MainActor
final class PaneGapLiveApplyTests: XCTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        // Instant split. `animateSplitIn` detaches the very constraints under test while it runs,
        // so an animated split would measure a frame mid-slide.
        Motion.isReduceMotionEnabled = { true }
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        MotionConfig.apply(.system)
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// The gap a user actually sees between the two stacked panes.
    private func measuredPaneGap(_ controller: WindowController) -> CGFloat? {
        let root = controller.window.contentView!
        root.layoutSubtreeIfNeeded()
        let hosts = descendants(of: root).compactMap { $0 as? PanelHostView }
        guard hosts.count >= 2 else { return nil }
        let frames = hosts.map { $0.convert($0.bounds, to: root) }.sorted { $0.minY < $1.minY }
        return frames[1].minY - frames[0].maxY
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    func test_paneGapChange_reachesAnAlreadySplitCanvas() throws {
        var config = GeneralConfig.builtIn
        config.panelGap = 8
        GeneralConfig.setCurrentForTesting(config)

        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        self.controller = controller
        controller.showAndStart()
        controller.handle(.splitHorizontal)
        drainMainQueue()

        XCTAssertEqual(
            try XCTUnwrap(measuredPaneGap(controller)), 8, accuracy: 0.5,
            "the split should start at the configured gap")

        config.panelGap = 40
        GeneralConfig.setCurrentForTesting(config)
        NotificationCenter.default.post(
            name: .configDidChange, object: nil,
            userInfo: [ConfigChange.userInfoKey: ConfigChange.chromeLayout])
        drainMainQueue()

        XCTAssertEqual(
            try XCTUnwrap(measuredPaneGap(controller)), 40, accuracy: 0.5,
            "a pane-gap edit never reached the live split — it needs a relaunch again")
    }
}
