import AppKit
import PaneKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class PaneBackgroundOverrideTests: WindowTestCase {
    private var window: NSWindow!
    private var controller: PaneCanvasController!
    private var originalConfig: GeneralConfig!

    private let osc11 = TerminalColor(red: 0x3B, green: 0x2E, blue: 0x2E)

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

    private func layout() { controller.canvasView.layoutSubtreeIfNeeded() }

    private func host(showing surface: TerminalSurface) -> PanelHostView? {
        controller.hostsForTesting.values.first { surface.view.isDescendant(of: $0) }
    }

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

    func test_backgroundChangeReachesTheRingWhenTranslucent() throws {
        var config = GeneralConfig.builtIn
        config.backgroundAlpha = 0.5
        GeneralConfig.setCurrentForTesting(config)
        let surface = try XCTUnwrap(controller.allSurfaces.first)
        let host = try XCTUnwrap(host(showing: surface))

        controller.surface(surface, backgroundDidChange: osc11)

        let painted = host.paintedBackgroundForTesting
        XCTAssertNil(painted.fill, "the clip should not fill while the background is translucent")
        let ring = try XCTUnwrap(painted.ring.usingColorSpace(.sRGB))
        XCTAssertEqual(ring.redComponent, osc11.nsColor.redComponent, accuracy: 0.01)
        XCTAssertEqual(ring.greenComponent, osc11.nsColor.greenComponent, accuracy: 0.01)
        XCTAssertEqual(ring.blueComponent, osc11.nsColor.blueComponent, accuracy: 0.01)
        XCTAssertEqual(
            ring.alphaComponent, 0.5, accuracy: 0.01,
            "the ring has to blend at the same alpha the terminal does")
    }

    func test_aLaterChangeReplacesTheEarlierOne() throws {
        let surface = try XCTUnwrap(controller.allSurfaces.first)
        let host = try XCTUnwrap(host(showing: surface))
        let restored = Theme.current.chrome.background

        controller.surface(surface, backgroundDidChange: osc11)
        controller.surface(surface, backgroundDidChange: restored)

        assertPaints(host, restored, "the second change did not replace the first")
    }

    func test_themeReloadDoesNotClobberTheOverride() throws {
        let surface = try XCTUnwrap(controller.allSurfaces.first)
        let host = try XCTUnwrap(host(showing: surface))
        controller.surface(surface, backgroundDidChange: osc11)

        controller.reapplyChromeColors()

        assertPaints(host, osc11, "a theme reload dropped the program's background")
    }
}
