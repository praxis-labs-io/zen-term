import AppKit
import PaneKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// ZEN-23: a program that repaints its own background (OSC 11) moves the fill of ITS pane and
/// nothing else. libghostty already repaints the grid below the seam, so what is at stake here is
/// the padding the chrome paints around that grid: get the routing wrong and a repainted pane sits
/// inside a ring of the old theme color, which is the state this ticket found.
///
/// Window-mounted per the house rule, and the assertions read the colors off the real layer and
/// ring view (`paintedBackgroundForTesting`) rather than off the `backgroundOverride` that was set
/// — a hook that never reached the paint has to fail.
final class PaneBackgroundOverrideTests: XCTestCase {
    private var window: NSWindow!
    private var controller: PaneCanvasController!

    private let osc11 = TerminalColor(red: 0x3B, green: 0x2E, blue: 0x2E)

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

    /// The host that actually contains a surface's view, found by walking the built tree rather
    /// than by asking the controller — the same containment the user sees, so a surface routed to
    /// the wrong host can't satisfy it.
    private func host(showing surface: TerminalSurface) -> PanelHostView? {
        controller.hostsForTesting.values.first { surface.view.isDescendant(of: $0) }
    }

    /// The color a panel is painting its interior with: the clip's fill while the background is
    /// solid, the ring's while it is translucent.
    private func paintedColor(_ host: PanelHostView) -> NSColor? {
        let painted = host.paintedBackgroundForTesting
        guard let fill = painted.fill else { return painted.ring }
        return NSColor(cgColor: fill)
    }

    private func assertPaints(
        _ host: PanelHostView, _ expected: TerminalColor, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let painted = paintedColor(host)?.usingColorSpace(.sRGB) else {
            return XCTFail("the panel painted no interior color", file: file, line: line)
        }
        let want = expected.nsColor
        XCTAssertEqual(painted.redComponent, want.redComponent, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(painted.greenComponent, want.greenComponent, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(painted.blueComponent, want.blueComponent, accuracy: 0.01, message, file: file, line: line)
    }

    func test_backgroundChangeRepaintsOnlyItsOwnPane() throws {
        controller.split(.vertical)
        layout()
        let surfaces = controller.allSurfaces
        XCTAssertEqual(surfaces.count, 2)
        let repainted = try XCTUnwrap(host(showing: surfaces[0]))
        let untouched = try XCTUnwrap(host(showing: surfaces[1]))

        controller.surface(surfaces[0], backgroundDidChange: osc11)

        assertPaints(repainted, osc11, "the repainted pane's padding kept the theme background")
        assertPaints(
            untouched, Theme.current.chrome.background,
            "a program repainted a pane it does not own")
    }

    /// nil is how the backend reports OSC 111, and it has to put the pane back rather than pin it
    /// to a color.
    func test_nilPutsThePaneBackOnTheTheme() throws {
        let surface = try XCTUnwrap(controller.allSurfaces.first)
        let host = try XCTUnwrap(host(showing: surface))

        controller.surface(surface, backgroundDidChange: osc11)
        controller.surface(surface, backgroundDidChange: nil)

        assertPaints(
            host, Theme.current.chrome.background, "the reset left the program's color painted")
    }

    /// A theme reload re-runs `applyBackground` on every pane. libghostty keeps an OSC-set color
    /// through a config change, so the grid stays repainted — and the chrome has to as well, or the
    /// reload is what reintroduces the mismatched ring.
    func test_themeReloadDoesNotClobberTheOverride() throws {
        let surface = try XCTUnwrap(controller.allSurfaces.first)
        let host = try XCTUnwrap(host(showing: surface))
        controller.surface(surface, backgroundDidChange: osc11)

        controller.reapplyChromeColors()

        assertPaints(host, osc11, "a theme reload dropped the program's background")
    }

    /// Hosts are built lazily, so a surface can already be repainted by the time the chrome makes
    /// the view that has to match it. The pull (`TerminalSurface.backgroundOverride`) is what
    /// covers that, and it is the only thing covering a tool float, whose card is rebuilt on every
    /// open while its surface lives on in the background.
    func test_aHostBuiltForAnAlreadyRepaintedSurfaceTakesItsColor() throws {
        let surface = RecordingSurface()
        surface.backgroundOverride = osc11
        let fresh = PaneCanvasController(makeSurface: { surface })
        defer { fresh.shutdown() }
        let canvas = fresh.canvasView
        canvas.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView?.addSubview(canvas)
        fresh.start()
        canvas.layoutSubtreeIfNeeded()

        let host = try XCTUnwrap(fresh.hostsForTesting[fresh.focusedLeafID])
        assertPaints(host, osc11, "the new host ignored the background its surface was already on")
    }
}
