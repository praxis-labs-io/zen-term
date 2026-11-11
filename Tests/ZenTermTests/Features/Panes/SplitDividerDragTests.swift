import AppKit
import PaneKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class SplitDividerDragTests: WindowTestCase {
    private var window: NSWindow!
    private var controller: PaneCanvasController!
    private var originalConfig: GeneralConfig!

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        Motion.isReduceMotionEnabled = { true }
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
        GeneralConfig.setCurrentForTesting(originalConfig)
        super.tearDown()
    }

    private func layout() { controller.canvasView.layoutSubtreeIfNeeded() }

    private func dividers(in view: NSView) -> [SplitDivider] {
        view.subviews.flatMap { ($0 as? SplitDivider).map { [$0] } ?? dividers(in: $0) }
    }

    private func divider(_ axis: SplitAxis) throws -> SplitDivider {
        try XCTUnwrap(dividers(in: controller.canvasView).first { $0.axis == axis })
    }

    private func center(of divider: SplitDivider) -> CGPoint {
        divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func drag(_ divider: SplitDivider, from start: CGPoint, to end: CGPoint) throws {
        divider.mouseDown(with: try mouse(.leftMouseDown, at: start))
        divider.mouseDragged(with: try mouse(.leftMouseDragged, at: end))
        divider.mouseUp(with: try mouse(.leftMouseUp, at: end))
        layout()
    }

    private func width(of id: PaneID) -> CGFloat { controller.hostsForTesting[id]?.bounds.width ?? 0 }

    func test_drag_movesTheSplitInPlace() throws {
        let first = controller.focusedLeafID
        controller.split(.vertical)
        layout()
        let hostsBefore = controller.hostsForTesting
        let superviewsBefore = hostsBefore.compactMapValues { $0.superview }
        let divider = try divider(.vertical)
        let start = center(of: divider)

        try drag(divider, from: start, to: CGPoint(x: 540, y: start.y))

        XCTAssertEqual(width(of: first), 0.6 * 900 - ChromeMetrics.panelGap / 2, accuracy: 1.0)
        for (id, host) in controller.hostsForTesting {
            XCTAssertTrue(host === hostsBefore[id], "a drag must not recreate any host")
            XCTAssertTrue(host.superview === superviewsBefore[id], "a drag must not rebuild the split containers")
        }
    }

    func test_drag_survivesARebuild() throws {
        let first = controller.focusedLeafID
        controller.split(.vertical)
        layout()
        let divider = try divider(.vertical)
        let start = center(of: divider)

        try drag(divider, from: start, to: CGPoint(x: 540, y: start.y))
        controller.zoomFocusedLeaf()
        layout()
        controller.unzoom()
        layout()

        XCTAssertEqual(width(of: first), 0.6 * 900 - ChromeMetrics.panelGap / 2, accuracy: 1.0)
    }

    func test_drag_clampsAtMinExtent() throws {
        controller.split(.vertical)
        layout()
        let divider = try divider(.vertical)
        let start = center(of: divider)

        try drag(divider, from: start, to: CGPoint(x: 0, y: start.y))

        for host in controller.hostsForTesting.values {
            XCTAssertGreaterThanOrEqual(host.bounds.width, 240, "a drag must never push a pane under the 240pt floor")
        }
    }

    func test_drag_keepsTheGrabOffset() throws {
        let first = controller.focusedLeafID
        controller.split(.vertical)
        layout()
        let before = width(of: first)
        let divider = try divider(.vertical)
        let offCenter = CGPoint(x: center(of: divider).x + 3, y: center(of: divider).y)

        try drag(divider, from: offCenter, to: offCenter)

        XCTAssertEqual(width(of: first), before, accuracy: 0.5, "a press off center must not jump the split")
    }

    func test_drag_leavesFocusWhereItWas() throws {
        controller.split(.vertical)
        layout()
        let focused = controller.focusedLeafID
        let divider = try divider(.vertical)
        let start = center(of: divider)

        try drag(divider, from: start, to: CGPoint(x: 360, y: start.y))

        XCTAssertEqual(controller.focusedLeafID, focused)
    }

    func test_drag_onANestedDivider_movesOnlyItsOwnSplit() throws {
        let left = controller.focusedLeafID
        controller.split(.vertical)
        layout()
        let top = controller.focusedLeafID
        controller.split(.horizontal)
        layout()
        let leftWidth = width(of: left)
        let topHeight = controller.hostsForTesting[top]?.bounds.height ?? 0
        let divider = try divider(.horizontal)
        let start = center(of: divider)

        try drag(divider, from: start, to: CGPoint(x: start.x, y: start.y - 40))

        XCTAssertEqual(width(of: left), leftWidth, accuracy: 0.5, "the outer split must not move")
        XCTAssertEqual(controller.hostsForTesting[top]?.bounds.height ?? 0, topHeight + 40, accuracy: 1.0)
    }

    func test_drag_downward_growsTheTopPane() throws {
        let top = controller.focusedLeafID
        controller.split(.horizontal)
        layout()
        let before = controller.hostsForTesting[top]?.bounds.height ?? 0
        let divider = try divider(.horizontal)
        let start = center(of: divider)

        try drag(divider, from: start, to: CGPoint(x: start.x, y: start.y - 40))

        XCTAssertEqual(controller.hostsForTesting[top]?.bounds.height ?? 0, before + 40, accuracy: 1.0)
    }

    func test_drag_stopsReportingOnceARebuildRemovesTheDivider() throws {
        let first = controller.focusedLeafID
        controller.split(.vertical)
        layout()
        let divider = try divider(.vertical)
        let start = center(of: divider)

        divider.mouseDown(with: try mouse(.leftMouseDown, at: start))
        controller.zoomFocusedLeaf()
        layout()
        divider.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 540, y: start.y)))
        controller.unzoom()
        layout()

        XCTAssertEqual(width(of: first), 0.5 * 900 - ChromeMetrics.panelGap / 2, accuracy: 1.0)
    }

    func test_divider_isTheHitTargetOverThePaneEdges_atZeroPaneGap() throws {
        controller.split(.vertical)
        layout()
        var config = GeneralConfig.current
        config.panelGap = 0
        GeneralConfig.setCurrentForTesting(config)
        controller.reapplyChromeLayout()
        layout()
        let divider = try divider(.vertical)
        let content = try XCTUnwrap(window.contentView)

        XCTAssertTrue(
            content.hitTest(center(of: divider)) === divider, "the divider must sit above the panes it overlaps")
    }

    func test_divider_doesNotMoveTheWindow() throws {
        controller.split(.vertical)
        layout()

        XCTAssertFalse(try divider(.vertical).mouseDownCanMoveWindow)
    }

    func test_divider_keepsAGrabBand_atZeroPaneGap() throws {
        controller.split(.vertical)
        layout()
        var config = GeneralConfig.current
        config.panelGap = 0
        GeneralConfig.setCurrentForTesting(config)

        controller.reapplyChromeLayout()
        layout()

        XCTAssertEqual(try divider(.vertical).frame.width, ChromeMetrics.Spacing.s8, accuracy: 0.5)
    }
}
