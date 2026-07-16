import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// `WindowController.showToast` is the seam `AppDelegate` routes app-global notices through — today
/// the config keybind conflicts of ZEN-142. The content is unit-tested elsewhere; this asserts the
/// notice actually reaches the screen, per the house rule that a control tested only through its
/// view-model can ship dead. A silent no-op here would leave the whole feature invisible.
@MainActor
final class WindowControllerToastSeamTests: XCTestCase {
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

    private func makeController() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), initialCWD: nil)
        self.controller = controller
        return controller
    }

    func test_showToast_mountsAVisibleToastInTheWindow() throws {
        let controller = makeController()
        XCTAssertTrue(toastViews(in: controller).isEmpty, "no toast before one is asked for")

        controller.showToast(
            ConfigDiagnostic.toast(for: [
                ConfigDiagnostic(
                    scope: .keybind(.splitVertical), problem: .noShortcut,
                    message: "⌘⇧\\ went to toggle_zoom in your config.")
            ])!)

        let toasts = toastViews(in: controller)
        XCTAssertEqual(toasts.count, 1, "the seam must actually mount a toast, not swallow it")
        // Assert the rendered text, not the content struct — the struct is already unit-tested; what
        // could still be broken is the card rendering something other than what it was handed.
        let labels = descendants(of: toasts[0]).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains { $0.contains("Split Vertically") }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.contains("toggle_zoom") }, "\(labels)")
    }

    func test_showToast_isReachableFromTheKeyWindowLookup() {
        // AppDelegate routes through `keyController()`, which falls back to the first window when
        // none is key (the headless case here). If the seam weren't public to it, this wouldn't
        // compile — and the config toast would never have a window to land in.
        let controller = makeController()
        controller.showToast(ToastContent(variant: .warning, title: "Title", message: "Body"))
        XCTAssertEqual(toastViews(in: controller).count, 1)
    }
}
