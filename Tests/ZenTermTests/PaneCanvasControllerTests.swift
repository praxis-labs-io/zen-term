import AppKit
import PaneKit
import TerminalKit
import XCTest

@testable import ZenTerm

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

    func test_commandCompletionRelaysFromPaneToTabOwner() throws {
        var received: TerminalCommandResult?
        controller.onCommandFinished = { received = $1 }
        let surface = try XCTUnwrap(controller.surface(for: controller.focusedLeafID))
        let result = TerminalCommandResult(exitCode: 0, duration: 42)

        surface.delegate?.surface(surface, commandDidFinish: result)

        XCTAssertEqual(received, result)
    }

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
        let expected = 0.54 * 900 - ChromeMetrics.panelGap / 2
        XCTAssertEqual(controller.hostsForTesting[first]?.bounds.width ?? 0, expected, accuracy: 1.0)
        XCTAssertEqual(controller.focusedLeafID, second, "resize keeps focus where it was")
    }

    func test_resize_withoutBuiltContainers_fallsBackToRebuild() {
        let first = controller.focusedLeafID
        controller.split(.vertical)
        layout()

        controller.zoomFocusedLeaf()
        layout()
        controller.resize(.right)
        controller.unzoom()
        layout()

        let expected = 0.54 * 900 - ChromeMetrics.panelGap / 2
        XCTAssertEqual(controller.hostsForTesting[first]?.bounds.width ?? 0, expected, accuracy: 1.0)
    }

    func test_resize_clampsAtMinExtent() {
        controller.split(.vertical)
        layout()

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
        _ = window
        defer { controller.shutdown() }
        drainMainQueue()

        XCTAssertEqual(surface.startCount, 1, "the pane started once")
        XCTAssertEqual(failureCount, 1, "the dead surface fired the failure hook")
        XCTAssertEqual(controller.paneCount, 1, "the dead pane stays put until retry/close answers")
        guard let captured else { return XCTFail("the failure hook must hand up retry/close actions") }

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
        drainMainQueue()

        guard let close = captured else { return XCTFail("the failure hook must hand up a close action") }
        close()
        XCTAssertTrue(
            lastPaneClosed, "closing the only (dead) pane routes through the normal last-pane path")
    }

    func test_aHaloRefreshDoesNotUndoTheUnfocusedRender() throws {
        let surface = try XCTUnwrap(controller.surface(for: controller.focusedLeafID) as? RecordingSurface)

        controller.setFocusedSurfaceRendersFocused(false)
        XCTAssertEqual(surface.focusRenders.last, false)

        controller.setPanesFocused(true)

        XCTAssertEqual(surface.focusRenders.last, false, "the mode still holds the keyboard")
    }

    func test_zoomingTheFocusedLeafAnnouncesNoFocusMove() {
        controller.split(.vertical)
        layout()
        var moves = 0
        controller.onFocusChanged = { moves += 1 }

        controller.zoomFocusedLeaf()
        layout()

        XCTAssertEqual(
            moves, 0,
            "a zoom re-focuses the leaf it already held; announcing it ends every mode over that pane")
    }

    func test_focusComingBackFromADrawerAnnouncesTheMove() {
        controller.setPanesFocused(false)
        var moves = 0
        controller.onFocusChanged = { moves += 1 }

        controller.focusActivePane()

        XCTAssertEqual(moves, 1, "focus returning from a drawer is a real move")
    }
}
