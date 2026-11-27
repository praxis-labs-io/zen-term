import AppKit
import XCTest

@testable import TerminalKit
@testable import ZenTerm

final class PaneReadViewportTests: XCTestCase {
    private var window: NSWindow!
    private var surfaces: [GhosttySurface] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
    }

    override func tearDown() {
        for surface in surfaces {
            surface.view.removeFromSuperview()
            surface.terminate()
        }
        surfaces = []
        window.close()
        window = nil
        super.tearDown()
    }

    private func mounted(_ script: String) throws -> GhosttySurface {
        let surface = GhosttySurface()
        surfaces.append(surface)
        surface.start(TerminalSurfaceConfig(command: "/bin/sh", args: ["-c", script + "; sleep 100"]))
        try XCTSkipIf(surface.surfacePtr == nil, "ghostty_surface_new failed")
        surface.view.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        window.contentView?.addSubview(surface.view)
        return surface
    }

    private func rowByRow(_ surface: TerminalSurface) -> String? {
        guard let rows = surface.cellMetrics?.rows else { return nil }
        var lines = (0..<rows).map { surface.text(viewportRow: $0) ?? "" }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    func test_theViewportReadsAsTodaysRowByRowRead_withWrappedLinesOnScreen() throws {
        let script =
            #"seq 300; printf 'W%0300d\n  indented  \na\tb\na\346\274\242b   \n\n'; printf 'E%0150d\n' 0; echo END"#
        let surface = try mounted(script)
        waitUntil(rowByRow(surface)?.hasSuffix("END") == true, "the script's last line", timeout: 10)
        let grid = try XCTUnwrap(surface.grid)
        let top = grid.viewportTop
        let rows = try XCTUnwrap(surface.cellMetrics?.rows)
        XCTAssertTrue((top..<top + rows).contains { grid.row($0)?.wraps == true }, "no wrapped line on screen")

        XCTAssertEqual(ControlResponder.viewport(of: surface), rowByRow(surface))

        surface.scroll(.lines(-(rows + 5)))
        waitUntil(grid.viewportTop < top, "the viewport to scroll back", timeout: 5)
        XCTAssertEqual(ControlResponder.viewport(of: surface), rowByRow(surface), "scrolled into the scrollback")
    }
}
