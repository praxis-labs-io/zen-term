import AppKit
import PaneKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// A chrome strip inside a pane has to paint on the pane's own fill.
///
/// The chrome's tints are alpha inks tuned to sit on an opaque background. Below `background-alpha`
/// the pane deliberately has no opaque fill (the clip stops filling so the grid can show through),
/// so the find bar's accent-at-0.14 composited straight onto whatever was behind the window and read
/// grey. The padding ring was already the exception: it paints the theme background at the pane's
/// alpha. This pins the strip to the same rule.
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

    private var tintAlpha: CGFloat { 0.14 }  // FindBarView.fillAlpha, the faintest accent fill

    // MARK: the strip carries the pane's fill

    func test_findBar_paintsAtThePanesAlpha_notItsTintAlone() throws {
        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)
        let host = try focusedHost()
        // A black pane background makes the composite closed-form: every channel of the result is the
        // tint's channel scaled by its share of the combined alpha.
        controller.surface(
            try XCTUnwrap(controller.allSurfaces.first),
            backgroundDidChange: TerminalColor(red: 0, green: 0, blue: 0))

        let fill = try barFill(host)

        let expectedAlpha = tintAlpha + 0.5 * (1 - tintAlpha)
        XCTAssertEqual(
            fill.alphaComponent, expectedAlpha, accuracy: 0.01,
            "the bar carries the pane's fill under its tint, so it is more opaque than either")
        let accent = try XCTUnwrap(Theme.current.chrome.accent.nsColor.usingColorSpace(.sRGB))
        let share = tintAlpha / expectedAlpha  // the black base contributes no color, only alpha
        XCTAssertEqual(fill.redComponent, accent.redComponent * share, accuracy: 0.02)
        XCTAssertEqual(fill.greenComponent, accent.greenComponent * share, accuracy: 0.02)
        XCTAssertEqual(fill.blueComponent, accent.blueComponent * share, accuracy: 0.02)
    }

    func test_findBar_isOpaqueWhileTheBackgroundIsSolid() throws {
        let host = try focusedHost()  // builtIn is alpha 1

        let fill = try barFill(host)

        XCTAssertEqual(
            fill.alphaComponent, 1, accuracy: 0.01,
            "on a solid pane the bar is the pane's fill plus its tint, which is opaque")
    }

    /// The ring is the surface the strip has to agree with, so its alpha is the floor.
    func test_findBar_isNeverFainterThanThePaddingRing() throws {
        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.3
        GeneralConfig.setCurrentForTesting(config)
        let host = try focusedHost()

        let fill = try barFill(host)
        let ring = try XCTUnwrap(host.paintedBackgroundForTesting.ring.usingColorSpace(.sRGB))

        XCTAssertGreaterThan(
            fill.alphaComponent, ring.alphaComponent,
            "a bar fainter than the ring it sits on is the grey wash this ticket is about")
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

    /// Below `background-alpha` the ring paints the padding with the terminal's frame punched out. A
    /// strip resizes the terminal, so that hole moves, but flipping a constraint doesn't mark the panel
    /// as needing layout and `layout()` is the only other thing that marks the ring. The band the strip
    /// sits in then goes unpainted and the window's backdrop shows through it.
    /// The header displaces the terminal exactly as the find bar does, and it had no re-read of
    /// its own: it marked a ring that was still hidden from the alpha the panel was built at, and
    /// a hidden view drops the request. Only the find bar's path happened to unhide first.
    func test_showingTheModeHeader_repaintsTheRing() throws {
        let host = try focusedHost()  // built under builtIn, alpha 1, so the ring is hidden
        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()  // clear the flag, so what it says next came from the header
        XCTAssertFalse(host.ringNeedsDisplayForTesting, "premise: nothing is queued before the header")

        host.modeMeta = PanelMeta(title: "Scroll", action: .toggleScrollMode)

        XCTAssertTrue(
            host.ringNeedsDisplayForTesting,
            "the header shrank the terminal, so the ring's hole is stale until it repaints")
    }

    func test_togglingTheFindBar_repaintsTheRing() throws {
        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)
        let host = try focusedHost()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()  // clear the flag, so what it says next came from the toggle
        XCTAssertFalse(host.ringNeedsDisplayForTesting, "premise: nothing is queued before the toggle")

        _ = host.setFindBarShown(true)

        XCTAssertTrue(
            host.ringNeedsDisplayForTesting,
            "showing the bar shrank the terminal, so the ring's hole is stale until it repaints")

        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        _ = host.setFindBarShown(false)

        XCTAssertTrue(host.ringNeedsDisplayForTesting, "and hiding it moves the hole back")
    }
}
