import AppKit
import PaneKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// A seam-conforming fake so the canvas controller can run without a real backend.
private final class FakeSurface: NSObject, TerminalSurface {
    let view = NSView()
    weak var delegate: TerminalSurfaceDelegate?
    var title = ""
    var isFocused = false
    func start(_ config: TerminalSurfaceConfig) {}
    func focus() {}
    func terminate() {}
    func paste(_ text: String) {}
    func copySelection() -> String? { nil }
    func scrollToBottom() {}
}

/// ZEN-54: the canvas reuses each leaf's `PanelHostView` across restructures instead of
/// rebuilding the pane chrome on every reconcile. Window-mounted per the house rule, so the
/// assertions run against the real built view tree.
final class PaneCanvasControllerTests: XCTestCase {
    private var window: NSWindow!
    private var controller: PaneCanvasController!

    override func setUp() {
        super.setUp()
        controller = PaneCanvasController(makeSurface: { FakeSurface() })
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = controller.canvasView
        canvas.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView?.addSubview(canvas)
        controller.start()
        canvas.layoutSubtreeIfNeeded()
    }

    override func tearDown() {
        controller.shutdown()
        controller = nil
        window = nil
        super.tearDown()
    }

    private func layout() { controller.canvasView.layoutSubtreeIfNeeded() }

    func test_split_reusesRetainedHost() {
        let first = controller.focusedLeafID
        guard let original = controller.hostsForTesting[first] else {
            return XCTFail("the first leaf must have a host after start()")
        }

        controller.split(.vertical)
        layout()

        XCTAssertEqual(controller.paneCount, 2)
        XCTAssertTrue(
            controller.hostsForTesting[first] === original,
            "the retained leaf's host was rebuilt instead of reused")
        let newLeaf = controller.focusedLeafID
        XCTAssertNotEqual(newLeaf, first, "a split focuses the new leaf")
        XCTAssertNotNil(controller.hostsForTesting[newLeaf])
        XCTAssertFalse(controller.hostsForTesting[newLeaf] === original)
    }

    func test_resize_keepsHostIdentity() {
        controller.split(.vertical)
        layout()
        let hostsBefore = controller.hostsForTesting

        controller.resize(.right)
        layout()

        for (id, host) in controller.hostsForTesting {
            XCTAssertTrue(host === hostsBefore[id], "resize must not recreate any host")
        }
    }

    func test_resize_swapsRatioInPlace_withoutRebuildingContainers() {
        let first = controller.focusedLeafID
        controller.split(.vertical)
        layout()
        let second = controller.focusedLeafID
        let superviewsBefore = controller.hostsForTesting.compactMapValues { $0.superview }

        controller.resize(.right)
        layout()

        for (id, host) in controller.hostsForTesting {
            XCTAssertTrue(
                host.superview === superviewsBefore[id],
                "an in-place resize must not rebuild the split containers")
        }
        // `.right` on the flush-right focused pane moves the shared divider right:
        // ratio 0.5 → 0.54, so the first (left) pane grows by one step.
        let expected = 0.54 * 900 - ChromeMetrics.panelGap / 2
        XCTAssertEqual(controller.hostsForTesting[first]?.bounds.width ?? 0, expected, accuracy: 1.0)
        XCTAssertEqual(controller.focusedLeafID, second, "resize keeps focus where it was")
    }

    func test_resizeWhileZoomed_fallsBackAndAppliesRatio() {
        let first = controller.focusedLeafID
        controller.split(.vertical)
        layout()

        controller.zoomFocusedLeaf()
        layout()
        controller.resize(.right)  // no built containers while zoomed → full-rebuild fallback
        controller.unzoom()
        layout()

        let expected = 0.54 * 900 - ChromeMetrics.panelGap / 2
        XCTAssertEqual(controller.hostsForTesting[first]?.bounds.width ?? 0, expected, accuracy: 1.0)
    }

    func test_resize_clampsAtMinExtent() {
        controller.split(.vertical)
        layout()

        // One layout pass per nudge, like the runloop between key-repeat events — the
        // pixel clamp reads the split container's live bounds.
        for _ in 0..<20 {
            controller.resize(.left)
            layout()
        }

        for host in controller.hostsForTesting.values {
            XCTAssertGreaterThanOrEqual(
                host.bounds.width, 240,
                "spamming a resize must never push a pane under the 240pt floor")
        }
    }

    func test_zoomUnzoom_preservesHostIdentity() {
        let first = controller.focusedLeafID
        controller.split(.vertical)
        layout()
        let zoomLeaf = controller.focusedLeafID
        let hostsBefore = controller.hostsForTesting

        controller.zoomFocusedLeaf()
        layout()
        XCTAssertTrue(controller.isZoomed)
        let zoomedHost = controller.hostsForTesting[zoomLeaf]
        XCTAssertTrue(zoomedHost === hostsBefore[zoomLeaf], "zoom must reuse the cached host")
        XCTAssertTrue(
            zoomedHost?.superview === controller.canvasView,
            "the zoomed host renders full-canvas as the root")

        controller.unzoom()
        layout()
        XCTAssertFalse(controller.isZoomed)
        XCTAssertTrue(controller.hostsForTesting[first] === hostsBefore[first])
        XCTAssertTrue(controller.hostsForTesting[zoomLeaf] === hostsBefore[zoomLeaf])
    }

    func test_closeFocused_dropsOnlyThatHost() {
        let first = controller.focusedLeafID
        controller.split(.vertical)
        layout()
        let closed = controller.focusedLeafID
        guard let survivor = controller.hostsForTesting[first] else {
            return XCTFail("the retained leaf must have a host")
        }

        XCTAssertTrue(controller.closeFocused())
        layout()

        XCTAssertEqual(controller.paneCount, 1)
        XCTAssertNil(controller.hostsForTesting[closed], "the closed leaf's host must be pruned")
        XCTAssertTrue(controller.hostsForTesting[first] === survivor)
    }

    func test_closeWhileZoomed_endsZoomAndKeepsSurvivor() {
        let first = controller.focusedLeafID
        controller.split(.vertical)
        layout()
        guard let survivor = controller.hostsForTesting[first] else {
            return XCTFail("the retained leaf must have a host")
        }
        var zoomEnded = false
        controller.onZoomEnded = { zoomEnded = true }

        controller.zoomFocusedLeaf()
        layout()
        XCTAssertTrue(controller.closeFocused())
        layout()

        XCTAssertTrue(zoomEnded, "closing the zoomed leaf must end the zoom")
        XCTAssertFalse(controller.isZoomed)
        XCTAssertEqual(controller.paneCount, 1)
        XCTAssertTrue(controller.hostsForTesting[first] === survivor)
    }
}
