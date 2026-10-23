import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class PaneGapLiveApplyTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        Motion.isReduceMotionEnabled = { true }
    }

    override func tearDownWithError() throws {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        try super.tearDownWithError()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

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
        controller.mountAndStart()
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
