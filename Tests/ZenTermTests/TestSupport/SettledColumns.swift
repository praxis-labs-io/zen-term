import XCTest

@testable import TerminalKit

extension XCTestCase {
    // A shell can draw its prompt before the pane's frame reaches ghostty, which then rewraps what printed.
    func settledColumns(_ surface: GhosttySurface, _ grid: TerminalGrid) throws -> Int {
        let host = try XCTUnwrap(surface.view as? GhosttyHostView)
        let width = { grid.row(grid.viewportTop)?.cells.count }
        waitUntil(
            host.lastPushedFrameForTesting == host.bounds.size && width() == surface.cellMetrics?.columns,
            "the grid to take the pane's width", timeout: 5)
        return try XCTUnwrap(width())
    }
}
