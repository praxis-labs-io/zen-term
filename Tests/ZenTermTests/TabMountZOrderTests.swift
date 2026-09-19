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

    private func canvasHost(of controller: WindowController) -> NSView? {
        controller.containerForTesting.subviews.first { view in
            view.subviews.contains { canvas in descendants(of: canvas).contains { $0 is PanelHostView } }
        }
    }

    private func canvases(in host: NSView) -> [NSView] {
        host.subviews.filter { view in
            descendants(of: view).contains { $0 is PanelHostView }
        }
    }

    private func makeController() -> WindowController {
        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        self.controller = controller
        controller.mountAndStart()
        return controller
    }

    func test_incomingCanvasMountsAboveTheOutgoingOne() {
        let controller = makeController()

        guard let host = canvasHost(of: controller) else {
            return XCTFail("the window must hold a canvas host")
        }
        guard let outgoing = canvases(in: host).first else {
            return XCTFail("the first tab's canvas must be mounted after mountAndStart()")
        }

        controller.newTabForTesting()

        let mounted = canvases(in: host)
        XCTAssertEqual(
            mounted.count, 2, "the outgoing canvas stays mounted for the length of the transition")
        guard let incoming = mounted.first(where: { $0 !== outgoing }),
            let incomingIndex = host.subviews.firstIndex(of: incoming),
            let outgoingIndex = host.subviews.firstIndex(of: outgoing)
        else {
            return XCTFail("both canvases must be in the host during the transition")
        }
        XCTAssertGreaterThan(
            incomingIndex, outgoingIndex,
            "the arriving canvas sits above the outgoing one — under it, the transition and "
                + "anything animating on the new tab play invisibly and the swap reads as a cut")
        XCTAssertEqual(
            outgoingIndex, 0,
            "both canvases stay at the back of the host, below a float card dismissing above them")
        XCTAssertEqual(
            controller.containerForTesting.subviews.firstIndex(of: host), 0,
            "the canvas host sits at the back of the window, below a float card dismissing above it")
    }

    func test_aTabSlide_isClippedAtTheDockedSidebarsEdge_untilItLands() throws {
        let controller = makeController()
        if !controller.sidebarForTesting.isDocked { controller.handle(.toggleSidebar) }
        let sidebar = controller.sidebarForTesting.view
        waitUntil(sidebar.layer?.animationKeys()?.isEmpty ?? true, "the sidebar to finish docking")
        let host = try XCTUnwrap(canvasHost(of: controller), "the window must hold a canvas host")

        controller.newTabForTesting()

        let mask = try XCTUnwrap(host.layer?.mask, "the host clips while the slide runs")
        let clip = host.convert(mask.frame, to: controller.containerForTesting)
        XCTAssertEqual(
            clip.minX, sidebar.frame.maxX, accuracy: 0.5,
            "a sliding canvas stops at the sidebar's edge instead of crossing it")
        waitUntil(host.layer?.mask == nil, "the clip to lift once the slide lands")
    }
}
