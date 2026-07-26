import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// The toast stack's insets have to survive a chrome-layout change.
///
/// `ToastPresenter` pins its stack once at construction, and the presenter is built on the first
/// toast — so a `window-gutter` edit (or a `window-chrome` toggle, which moves `topInset` by the
/// 28pt traffic-light clearance) left an already-used window's toasts at the old offset until
/// relaunch. Same frozen-at-construction shape as the pane gap; different surface.
@MainActor
final class ToastInsetLiveApplyTests: XCTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var originalConfig: GeneralConfig!
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        Motion.isReduceMotionEnabled = { true }  // no spring-in mid-measurement
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

    /// Where the mounted toast actually sits, in window coordinates.
    private func toastOrigin(_ controller: WindowController) -> CGPoint? {
        let root = controller.window.contentView!
        root.layoutSubtreeIfNeeded()
        guard let toast = descendants(of: root).compactMap({ $0 as? ToastView }).first else {
            return nil
        }
        return toast.convert(toast.bounds, to: root).origin
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    func test_gutterChange_movesAnAlreadyMountedToastStack() throws {
        var config = GeneralConfig.builtIn
        config.windowGutter = 8
        GeneralConfig.setCurrentForTesting(config)

        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), initialCWD: nil)
        self.controller = controller
        controller.showAndStart()
        // Build the presenter, which is what freezes the insets.
        controller.showToast(ToastContent(variant: .info, title: "notice", message: "body"))
        drainMainQueue()

        let before = try XCTUnwrap(toastOrigin(controller), "expected a toast mounted")

        config.windowGutter = 48
        GeneralConfig.setCurrentForTesting(config)
        NotificationCenter.default.post(
            name: .configDidChange, object: nil,
            userInfo: [ConfigChange.userInfoKey: ConfigChange.chromeLayout])
        drainMainQueue()

        let after = try XCTUnwrap(toastOrigin(controller))
        // The gutter grew by 40, so the stack's trailing inset must pull it 40pt further left.
        XCTAssertEqual(
            before.x - after.x, 40, accuracy: 0.5,
            "a window-gutter edit never reached the mounted toast stack")
    }

    /// The re-point must not bring the presenter into existence. A window that has never shown a
    /// toast must still have no toast stack mounted after a gutter edit — otherwise the fix trades
    /// a stale inset for the z-order that building on first use exists to protect.
    func test_gutterChange_doesNotBuildTheToastStackInAWindowThatNeverShowedOne() throws {
        var config = GeneralConfig.builtIn
        config.windowGutter = 8
        GeneralConfig.setCurrentForTesting(config)

        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), initialCWD: nil)
        self.controller = controller
        controller.showAndStart()
        XCTAssertFalse(controller.hasBuiltToastsForTesting)

        config.windowGutter = 48
        GeneralConfig.setCurrentForTesting(config)
        NotificationCenter.default.post(
            name: .configDidChange, object: nil,
            userInfo: [ConfigChange.userInfoKey: ConfigChange.chromeLayout])
        drainMainQueue()

        XCTAssertFalse(
            controller.hasBuiltToastsForTesting,
            "the config observer constructed the toast presenter — it must only re-point an existing one")
        XCTAssertNil(toastOrigin(controller), "no toast should be mounted")
    }
}
