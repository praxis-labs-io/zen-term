import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class LinkPreviewTests: WindowTestCase {
    private var window: NSWindow!
    private var controller: PaneCanvasController!
    private var originalConfig: GeneralConfig!

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
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

    private func shownPreviews() -> [LinkPreviewView] {
        window.contentView?.subviews.compactMap { $0 as? LinkPreviewView } ?? []
    }

    func test_hoveredLinkShowsThePreviewAndNilClearsIt() throws {
        let surface = try XCTUnwrap(controller.allSurfaces.first)

        controller.surface(surface, hoveredLinkDidChange: "https://example.com/docs")

        let preview = try XCTUnwrap(shownPreviews().first, "the hovered link mounted no preview")
        XCTAssertEqual(preview.urlForTesting, "https://example.com/docs")

        controller.surface(surface, hoveredLinkDidChange: nil)

        XCTAssertTrue(shownPreviews().isEmpty, "leaving the link left the preview mounted")
    }

    func test_aSecondLinkReplacesThePreview() throws {
        let surface = try XCTUnwrap(controller.allSurfaces.first)

        controller.surface(surface, hoveredLinkDidChange: "https://example.com/first")
        controller.surface(surface, hoveredLinkDidChange: "https://example.com/second")

        XCTAssertEqual(shownPreviews().count, 1)
        XCTAssertEqual(shownPreviews().first?.urlForTesting, "https://example.com/second")
    }

    func test_aStaleClearFromAnotherPaneDoesNotHideThePreview() throws {
        controller.split(.vertical)
        controller.canvasView.layoutSubtreeIfNeeded()
        let surfaces = controller.allSurfaces
        XCTAssertEqual(surfaces.count, 2)

        controller.surface(surfaces[0], hoveredLinkDidChange: "https://example.com/old")
        controller.surface(surfaces[1], hoveredLinkDidChange: "https://example.com/new")
        controller.surface(surfaces[0], hoveredLinkDidChange: nil)

        XCTAssertEqual(
            shownPreviews().first?.urlForTesting, "https://example.com/new",
            "the old pane's clear tore down the new pane's preview")
    }

    func test_closingTheOwningPaneDismissesThePreviewOnTheNextEvent() throws {
        controller.split(.vertical)
        controller.canvasView.layoutSubtreeIfNeeded()
        let surfaces = controller.allSurfaces
        XCTAssertEqual(surfaces.count, 2)
        controller.surface(surfaces[0], hoveredLinkDidChange: "https://example.com/gone")
        XCTAssertEqual(shownPreviews().count, 1)

        controller.surfaceDidExit(surfaces[0], code: 0)
        controller.canvasView.layoutSubtreeIfNeeded()
        try sendMouseMoved()

        XCTAssertTrue(shownPreviews().isEmpty, "the closed pane's preview outlived its owner")
    }

    func test_anInputEventWithALiveOwnerKeepsThePreview() throws {
        let surface = try XCTUnwrap(controller.allSurfaces.first)
        controller.surface(surface, hoveredLinkDidChange: "https://example.com/live")

        try sendMouseMoved()

        XCTAssertEqual(shownPreviews().count, 1)
    }

    private func sendMouseMoved() throws {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0,
                pressure: 0))
        NSApp.sendEvent(event)
    }

    func test_aLongURLTruncatesInsteadOfGrowingTheCard() throws {
        let surface = try XCTUnwrap(controller.allSurfaces.first)
        let longURL = "https://example.com/" + String(repeating: "segment/", count: 60)

        controller.surface(surface, hoveredLinkDidChange: longURL)

        let preview = try XCTUnwrap(shownPreviews().first)
        XCTAssertEqual(preview.urlForTesting, longURL)
        XCTAssertLessThanOrEqual(
            preview.frame.width, LinkPreviewView.maxTextWidth + 18,
            "a long URL grew the card past the text budget plus its 9pt insets")
    }
}
