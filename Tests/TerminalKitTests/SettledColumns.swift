import XCTest

@testable import TerminalKit

extension XCTestCase {
    // A surface is born at a default size and takes its view's size a main-queue turn after mounting, rewrapping the grid.
    func settledColumns(_ surface: GhosttySurface, _ grid: TerminalGrid, timeout: TimeInterval = 20) throws -> Int {
        let host = try XCTUnwrap(surface.view as? GhosttyHostView)
        let width = { grid.row(grid.viewportTop)?.cells.count }
        let settled = { host.lastPushedFrameForTesting == host.bounds.size && width() == surface.cellMetrics?.columns }
        let deadline = Date().addingTimeInterval(timeout)
        while !settled(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(settled(), "the grid never took the view's width")
        return try XCTUnwrap(width())
    }
}
