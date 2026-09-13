import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class ToastInsetLiveApplyTests: WindowTestCase {
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
        controller.mountAndStart()
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
        XCTAssertEqual(
            before.x - after.x, 40, accuracy: 0.5,
            "a window-gutter edit never reached the mounted toast stack")
    }

    func test_gutterChange_doesNotBuildTheToastStackInAWindowThatNeverShowedOne() throws {
        var config = GeneralConfig.builtIn
        config.windowGutter = 8
        GeneralConfig.setCurrentForTesting(config)

        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), initialCWD: nil)
        self.controller = controller
        controller.mountAndStart()
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
