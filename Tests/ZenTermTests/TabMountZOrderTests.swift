import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class TabMountZOrderTests: WindowTestCase {
    private var originalOverride: (() -> TerminalSurface)?
    private var controller: WindowController?

    override func setUp() {
        super.setUp()
        originalOverride = TerminalSurfaceFactory.makeOverride
        TerminalSurfaceFactory.makeOverride = { RecordingSurface() }
        Motion.isReduceMotionEnabled = { false }
    }

    override func tearDown() {
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller = nil
        TerminalSurfaceFactory.makeOverride = originalOverride
        super.tearDown()
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func container(of controller: WindowController) -> NSView? {
        guard let root = controller.window.contentView,
            let bar = descendants(of: root).first(where: { $0 is TabBarView })
        else { return nil }
        return bar.superview
    }

    private func canvases(in container: NSView) -> [NSView] {
        container.subviews.filter { view in
            descendants(of: view).contains { $0 is PanelHostView }
        }
    }

    func test_incomingCanvasMountsAboveTheOutgoingOne() {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        self.controller = controller
        controller.mountAndStart()

        guard let container = container(of: controller) else {
            return XCTFail("the window must hold a tab bar and a canvas container")
        }
        guard let outgoing = canvases(in: container).first else {
            return XCTFail("the first tab's canvas must be mounted after mountAndStart()")
        }

        controller.newTabForTesting()

        let mounted = canvases(in: container)
        XCTAssertEqual(
            mounted.count, 2, "the outgoing canvas stays mounted for the length of the transition")
        guard let incoming = mounted.first(where: { $0 !== outgoing }),
            let incomingIndex = container.subviews.firstIndex(of: incoming),
            let outgoingIndex = container.subviews.firstIndex(of: outgoing)
        else {
            return XCTFail("both canvases must be in the container during the transition")
        }
        XCTAssertGreaterThan(
            incomingIndex, outgoingIndex,
            "the arriving canvas sits above the outgoing one — under it, the transition and "
                + "anything animating on the new tab play invisibly and the swap reads as a cut")
        XCTAssertEqual(
            outgoingIndex, 0,
            "both canvases stay at the back of the container, below a float card dismissing above them")
    }
}
