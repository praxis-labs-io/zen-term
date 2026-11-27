import AppKit
import PaneKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class PaneChromeSurfaceTests: WindowTestCase {
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

    private func focusedHost() throws -> PanelHostView {
        let surface = try XCTUnwrap(controller.allSurfaces.first)
        return try XCTUnwrap(controller.hostsForTesting.values.first { surface.view.isDescendant(of: $0) })
    }

    func test_surface_compositesTintOverBase() throws {
        let opaque = ChromeTheme.surface(
            tint: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5),
            over: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        let mid = try XCTUnwrap(opaque.usingColorSpace(.sRGB))
        XCTAssertEqual(mid.alphaComponent, 1, accuracy: 0.001, "over an opaque base the result is opaque")
        XCTAssertEqual(mid.redComponent, 0.5, accuracy: 0.001, "half white over black is mid grey")

        let translucent = ChromeTheme.surface(
            tint: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.2),
            over: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5))
        let blended = try XCTUnwrap(translucent.usingColorSpace(.sRGB))
        XCTAssertEqual(blended.alphaComponent, 0.6, accuracy: 0.001, "0.2 + 0.5 × 0.8")
        XCTAssertEqual(blended.redComponent, 0.2 / 0.6, accuracy: 0.001)
        XCTAssertEqual(blended.blueComponent, 0.4 / 0.6, accuracy: 0.001)
    }

    func test_surface_overNothing_isTheTint() throws {
        let onlyTint = ChromeTheme.surface(
            tint: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.25), over: .clear)
        let fill = try XCTUnwrap(onlyTint.usingColorSpace(.sRGB))
        XCTAssertEqual(fill.alphaComponent, 0.25, accuracy: 0.001)
        XCTAssertEqual(fill.redComponent, 1, accuracy: 0.001)
    }

    func test_hidingThePaneHeader_repaintsTheRing() throws {
        let host = try focusedHost()
        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        XCTAssertFalse(host.ringNeedsDisplayForTesting, "premise: nothing is queued before the header goes")

        config.paneHeaders = false
        GeneralConfig.setCurrentForTesting(config)
        host.reapplyChromeLayout()

        XCTAssertTrue(
            host.ringNeedsDisplayForTesting,
            "the header's going grew the terminal, so the ring's hole is stale until it repaints")
    }

    func test_openingFind_leavesTheTerminalsFrameAlone() throws {
        let host = try focusedHost()
        let terminal = try XCTUnwrap(controller.allSurfaces.first).view
        host.layoutSubtreeIfNeeded()
        let before = terminal.frame

        _ = host.setFindFieldShown(true)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(terminal.frame, before, "the field floats over the header, so the grid must not reflow")
    }
}
