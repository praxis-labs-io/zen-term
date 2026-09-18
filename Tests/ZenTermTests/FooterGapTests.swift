import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class FooterGapTests: WindowTestCase {
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

    private func applyGutter(_ gutter: CGFloat) {
        var config = GeneralConfig.builtIn
        config.windowGutter = gutter
        GeneralConfig.setCurrentForTesting(config)
    }

    private func liveApplyGutter(_ gutter: CGFloat, to controller: WindowController) {
        applyGutter(gutter)
        NotificationCenter.default.post(
            name: .configDidChange, object: nil,
            userInfo: [ConfigChange.userInfoKey: ConfigChange.chromeLayout])
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    private func seam(_ controller: WindowController) throws -> (footer: CGFloat, leading: CGFloat) {
        let root = try XCTUnwrap(controller.window.contentView)
        root.layoutSubtreeIfNeeded()
        let bar = try XCTUnwrap(
            descendants(of: root).compactMap { $0 as? TabBarView }.first, "no tab bar mounted")
        let pane = try XCTUnwrap(controller.focusedPanelForTesting, "no focused pane")
        let barRect = bar.convert(bar.bounds, to: root)
        let paneRect = pane.convert(pane.bounds, to: root)
        return (paneRect.minY - barRect.maxY, paneRect.minX - controller.sidebarForTesting.edgeOffsetForTesting)
    }

    func test_footerSeam_holdsAtEveryGutter() throws {
        applyGutter(0)
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), initialCWD: nil)
        self.controller = controller
        controller.mountAndStart()

        let zero = try seam(controller)
        XCTAssertEqual(
            zero.footer, ChromeMetrics.footerGap, accuracy: 0.5,
            "at window-gutter 0 the pane area collapsed onto the footer")
        XCTAssertEqual(zero.leading, 0, accuracy: 0.5)

        liveApplyGutter(64, to: controller)
        let wide = try seam(controller)
        XCTAssertEqual(
            wide.footer, ChromeMetrics.footerGap, accuracy: 0.5,
            "the footer seam tracked window-gutter instead of holding its own spacing")
        XCTAssertEqual(
            wide.leading, 64, accuracy: 0.5, "window-gutter stopped insetting the side edges")
    }
}
