import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// A pane surface that fails to start must surface an actionable toast rather than a
/// dead blank pane. Mounts the real chrome and drives the toast's ACTUAL buttons (per the house
/// rule that a control tested only through its view-model can ship dead) — asserting each button
/// runs its closure and dismisses the toast.
@MainActor
final class SurfaceFailureToastTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        originalOverride = TerminalSurfaceFactory.makeOverride
        // A real ghostty surface needs a live libghostty app; inject a headless stub instead.
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
    }

    override func tearDown() {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        super.tearDown()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func toastViews(in controller: WindowController) -> [ToastView] {
        guard let root = controller.window.contentView else { return [] }
        return descendants(of: root).compactMap { $0 as? ToastView }
    }

    private func button(_ title: String, in toast: ToastView) -> AppButton? {
        descendants(of: toast).compactMap { $0 as? AppButton }.first { $0.title == title }
    }

    private func makeController() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        return controller
    }

    func test_failureToast_mountsWithBothActions() {
        let controller = makeController()
        controller.presentSurfaceFailureToastForTesting(retry: {}, close: {})

        guard let toast = toastViews(in: controller).first else {
            return XCTFail("the surface-failure toast must mount in the window")
        }
        XCTAssertNotNil(button("Retry", in: toast), "the toast offers Retry")
        XCTAssertNotNil(button("Close Pane", in: toast), "the toast offers Close Pane")
    }

    func test_retryButton_runsRetryAndDismisses() {
        let controller = makeController()
        var retried = 0
        var closed = 0
        controller.presentSurfaceFailureToastForTesting(retry: { retried += 1 }, close: { closed += 1 })

        guard let toast = toastViews(in: controller).first,
            let retry = button("Retry", in: toast)
        else { return XCTFail("expected a mounted toast with a Retry button") }

        retry.performClick(nil)
        XCTAssertEqual(retried, 1, "clicking Retry runs the retry action")
        XCTAssertEqual(closed, 0, "Retry must not run the close action")

        waitUntil(toastViews(in: controller).isEmpty, "clicking Retry to dismiss the toast")
    }

    func test_closeButton_runsCloseAndDismisses() {
        let controller = makeController()
        var retried = 0
        var closed = 0
        controller.presentSurfaceFailureToastForTesting(retry: { retried += 1 }, close: { closed += 1 })

        guard let toast = toastViews(in: controller).first,
            let close = button("Close Pane", in: toast)
        else { return XCTFail("expected a mounted toast with a Close Pane button") }

        close.performClick(nil)
        XCTAssertEqual(closed, 1, "clicking Close Pane runs the close action")
        XCTAssertEqual(retried, 0, "Close Pane must not run the retry action")

        waitUntil(toastViews(in: controller).isEmpty, "clicking Close Pane to dismiss the toast")
    }
}
