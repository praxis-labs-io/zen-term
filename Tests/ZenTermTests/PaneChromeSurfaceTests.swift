import AppKit
import PaneKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// A strip inside a pane paints the pane's own color at full strength, since it floats over cells
/// the reader is trying to read. Its accent-at-0.14 alone composited onto the desktop and read grey.
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

    /// The find bar's painted fill, read off the layer rather than off the inputs.
    private func barFill(_ host: PanelHostView) throws -> NSColor {
        let bar = try XCTUnwrap(host.setFindBarShown(true))
        host.layoutSubtreeIfNeeded()
        let painted = try XCTUnwrap(bar.paintedFillForTesting)
        return try XCTUnwrap(NSColor(cgColor: painted)?.usingColorSpace(.sRGB))
    }

    // MARK: a floating strip covers what is behind it

    /// The bar floats over live cells, so a pane alpha reaching it would let the text read through.
    func test_findBar_isOpaqueAtEveryPaneAlpha() throws {
        for alpha in [1.0, 0.5, 0.3] {
            var config = GeneralConfig.builtIn
            config.backgroundAlpha = alpha
            GeneralConfig.setCurrentForTesting(config)
            let host = try focusedHost()

            let fill = try barFill(host)

            XCTAssertEqual(
                fill.alphaComponent, 1, accuracy: 0.01,
                "the bar covers terminal rows at background-alpha \(alpha)")
        }
    }

    // MARK: the composite itself

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

    // MARK: the ring's hole follows the terminal

    /// The zoom header still displaces the terminal, moving the hole the ring punches out of the
    /// padding, and flipping a constraint marks no layout pass. Without this the band goes bare.
    func test_zoomingAPane_repaintsTheRing() throws {
        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)
        let host = try focusedHost()
        host.reapplyTheme()  // the alpha above only reaches the ring through a background apply
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()  // clear the flag, so what it says next came from the zoom
        XCTAssertFalse(host.ringNeedsDisplayForTesting, "premise: nothing is queued before the zoom")

        host.isZoomed = true

        XCTAssertTrue(
            host.ringNeedsDisplayForTesting,
            "the header took a row off the terminal, so the ring's hole is stale until it repaints")

        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        host.isZoomed = false

        XCTAssertTrue(host.ringNeedsDisplayForTesting, "and unzooming moves the hole back")
    }
}
