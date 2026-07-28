import AppKit
import PaneKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// ZEN-54: the canvas reuses each leaf's `PanelHostView` across restructures instead of
/// rebuilding the pane chrome on every reconcile. Window-mounted per the house rule, so the
/// assertions run against the real built view tree.
final class PaneCanvasControllerTests: WindowTestCase {
    private var window: NSWindow!
    private var controller: PaneCanvasController!

    override func setUp() {
        super.setUp()
        controller = PaneCanvasController(makeSurface: { RecordingSurface() })
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

    /// Covers the defensive fallback in `resize(_:)` by driving the controller API directly —
    /// the chrome never resizes while zoomed (`TabController` blocks the chord), so zooming is
    /// just the only way to reach a split with no built container.
    func test_resize_withoutBuiltContainers_fallsBackToRebuild() {
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

    // MARK: ZEN-100 — surface-creation failure

    /// Window-mount a fresh controller and run its first reconcile. Returns the window so the
    /// caller retains it for the test's duration. Unlike the shared `setUp` controller, this
    /// lets a test wire `onSurfaceStartFailed` BEFORE `start()`, since the failure fires
    /// synchronously during that first reconcile.
    private func windowMounted(_ controller: PaneCanvasController) -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = controller.canvasView
        canvas.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        win.contentView?.addSubview(canvas)
        controller.start()
        canvas.layoutSubtreeIfNeeded()
        return win
    }

    /// Let any pending main-queue work run. The surface-failure callback is delivered
    /// asynchronously (see `TerminalSurfaceDelegate`), and the main queue is FIFO, so a drain
    /// enqueued after `start()` runs strictly after the failure it scheduled.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func test_surfaceFailsToStart_firesHook_andRetryReplaysLaunch() {
        let surface = RecordingSurface()
        surface.failOnStart = true
        let controller = PaneCanvasController(makeSurface: { surface })
        var failureCount = 0
        var captured: (retry: () -> Void, close: () -> Void)?
        controller.onSurfaceStartFailed = { retry, close in
            failureCount += 1
            captured = (retry, close)
        }
        let window = windowMounted(controller)
        _ = window  // retain the host window for the test's lifetime
        defer { controller.shutdown() }
        drainMainQueue()  // the failure callback is delivered async

        XCTAssertEqual(surface.startCount, 1, "the pane started once")
        XCTAssertEqual(failureCount, 1, "the dead surface fired the failure hook")
        XCTAssertEqual(controller.paneCount, 1, "the dead pane stays put until retry/close answers")
        guard let captured else { return XCTFail("the failure hook must hand up retry/close actions") }

        // Retry replays the SAME launch on the SAME surface; a now-succeeding start must not re-fire.
        surface.failOnStart = false
        captured.retry()
        XCTAssertEqual(surface.startCount, 2, "retry replays the stored launch")
        XCTAssertEqual(failureCount, 1, "a successful retry doesn't re-fire the failure hook")
        XCTAssertEqual(controller.paneCount, 1, "the retried pane survives")
    }

    func test_surfaceFailsToStart_closeActionDropsTheDeadPane() {
        let surface = RecordingSurface()
        surface.failOnStart = true
        let controller = PaneCanvasController(makeSurface: { surface })
        var captured: (() -> Void)?
        controller.onSurfaceStartFailed = { _, close in captured = close }
        var lastPaneClosed = false
        controller.onLastPaneClosed = { lastPaneClosed = true }
        let window = windowMounted(controller)
        _ = window
        defer { controller.shutdown() }
        drainMainQueue()  // the failure callback is delivered async

        guard let close = captured else { return XCTFail("the failure hook must hand up a close action") }
        close()
        XCTAssertTrue(
            lastPaneClosed, "closing the only (dead) pane routes through the normal last-pane path")
    }
}
