import AppKit
import XCTest

@testable import TerminalKit

/// A minimal in-test surface proving the protocol is coherent and usable
/// without any backend. If this compiles and routes a delegate call, the
/// seam's shape is sound.
private final class SpySurface: TerminalSurface {
    let view = NSView()
    weak var delegate: TerminalSurfaceDelegate?
    var title = "spy"
    var isFocused = false
    private(set) var started = false

    func start(_ config: TerminalSurfaceConfig) {
        started = true
        delegate?.surface(self, titleDidChange: "spy-started")
    }
    func focus() { isFocused = true }
    func terminate() {}
    func paste(_ text: String) {}
    func copySelection() -> String? { nil }
    func scroll(_ command: TerminalScroll) {}
}

private final class RecordingDelegate: TerminalSurfaceDelegate {
    var lastTitle: String?
    func surface(_ s: TerminalSurface, titleDidChange title: String) { lastTitle = title }
    // All other methods use the protocol's default no-op implementations.
}

final class SeamTests: XCTestCase {
    func test_startRoutesTitleThroughDelegate() {
        let surface = SpySurface()
        let recorder = RecordingDelegate()
        surface.delegate = recorder

        surface.start(TerminalSurfaceConfig())

        XCTAssertTrue(surface.started)
        XCTAssertEqual(recorder.lastTitle, "spy-started")
    }

    func test_configDefaults() {
        let config = TerminalSurfaceConfig()
        XCTAssertNil(config.command)
        XCTAssertTrue(config.args.isEmpty)
        XCTAssertTrue(config.environment.isEmpty)
    }

    func test_factoryMakesGhosttyByDefaultAndHonorsOverride() {
        // We construct only — starting a process is out of unit scope. The override is
        // process-global, so restore it for other tests.
        let original = TerminalSurfaceFactory.makeOverride
        defer { TerminalSurfaceFactory.makeOverride = original }

        TerminalSurfaceFactory.makeOverride = nil
        XCTAssertTrue(
            TerminalSurfaceFactory.make() is GhosttySurface,
            "libghostty is the sole backend (ZEN-45, ZEN-66)")

        let stub = SpySurface()
        TerminalSurfaceFactory.makeOverride = { stub }
        XCTAssertTrue(TerminalSurfaceFactory.make() is SpySurface)
    }
}

/// Where a viewport row sits inside the surface view (ZEN-330). The chrome draws scroll mode's
/// cursor band from this, and being one grid inset out puts every band a few pixels off the row
/// it names. That is a budget the eye can't check against a moving terminal, so it is measured.
final class TerminalCellMetricsTests: XCTestCase {
    private let metrics = TerminalCellMetrics(
        columns: 80, rows: 24, cellWidth: 8, cellHeight: 16, gridInset: 2)

    func test_theFirstRowStartsAtTheGridInsetNotAtZero() {
        // libghostty leaves blank space between the surface edge and the first cell. Placing row
        // 0 at y=0 rides that high on every row in the grid.
        XCTAssertEqual(metrics.rowFrame(0, width: 640), CGRect(x: 0, y: 2, width: 640, height: 16))
    }

    func test_eachRowIsOneCellFurtherDown() {
        XCTAssertEqual(metrics.rowFrame(3, width: 640).origin.y, 2 + 3 * 16)
        XCTAssertEqual(metrics.rowFrame(23, width: 640).origin.y, 2 + 23 * 16)
    }

    func test_aRowPastTheGridIsClampedIntoIt() {
        // A resize can leave a stale row index behind for one pass; it must not draw off-grid.
        XCTAssertEqual(metrics.rowFrame(99, width: 640), metrics.rowFrame(23, width: 640))
        XCTAssertEqual(metrics.rowFrame(-4, width: 640), metrics.rowFrame(0, width: 640))
    }

    func test_theFirstColumnStartsAtTheGridInsetToo() {
        // `window-padding-x` and `-y` are emitted at one value with balancing off.
        XCTAssertEqual(
            metrics.cellFrame(row: 0, columns: 0...0),
            CGRect(x: 2, y: 2, width: 8, height: 16))
    }

    func test_aRunOfCellsIsAsWideAsItHasCells() {
        XCTAssertEqual(
            metrics.cellFrame(row: 3, columns: 4...7),
            CGRect(x: 2 + 4 * 8, y: 2 + 3 * 16, width: 4 * 8, height: 16))
    }

    func test_aRunPastTheLastColumnStopsAtIt() {
        // The leftover strip past the last column holds no characters to paint over.
        XCTAssertEqual(metrics.cellFrame(row: 0, columns: 0...999).maxX, 2 + 80 * 8)
        XCTAssertEqual(metrics.cellFrame(row: 0, columns: -5...2).origin.x, 2)
    }
}

/// The span a yank reads and a selection paints. Ordering is the whole of its job: handed a
/// reversed span the backend reads nothing, so a selection dragged upward copies an empty string
/// while looking highlighted on screen.
final class TerminalViewportRangeTests: XCTestCase {
    func test_aForwardSpanIsLeftAlone() {
        let range = TerminalViewportRange(startRow: 2, startColumn: 4, endRow: 5, endColumn: 9)

        XCTAssertEqual(range.startRow, 2)
        XCTAssertEqual(range.startColumn, 4)
        XCTAssertEqual(range.endRow, 5)
        XCTAssertEqual(range.endColumn, 9)
    }

    func test_aSpanGivenBackwardsIsOrderedOnConstruction() {
        let range = TerminalViewportRange(startRow: 5, startColumn: 9, endRow: 2, endColumn: 4)

        XCTAssertEqual(range.startRow, 2)
        XCTAssertEqual(range.startColumn, 4)
        XCTAssertEqual(range.endRow, 5)
        XCTAssertEqual(range.endColumn, 9)
    }

    func test_theColumnsDecideTheOrderWhenTheRowsMatch() {
        let range = TerminalViewportRange(startRow: 3, startColumn: 12, endRow: 3, endColumn: 6)

        XCTAssertEqual(range.startColumn, 6)
        XCTAssertEqual(range.endColumn, 12)
    }

    func test_rowCountCountsBothPartialEnds() {
        let range = TerminalViewportRange(startRow: 4, startColumn: 70, endRow: 6, endColumn: 2)

        XCTAssertEqual(range.rowCount, 3)
        XCTAssertEqual(
            TerminalViewportRange(startRow: 4, startColumn: 0, endRow: 4, endColumn: 9).rowCount, 1)
    }
}
