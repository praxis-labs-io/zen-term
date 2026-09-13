import AppKit
import XCTest

@testable import TerminalKit

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
        let original = TerminalSurfaceFactory.makeOverride
        defer { TerminalSurfaceFactory.makeOverride = original }

        TerminalSurfaceFactory.makeOverride = nil
        XCTAssertTrue(
            TerminalSurfaceFactory.make() is GhosttySurface,
            "libghostty is the sole backend")

        let stub = SpySurface()
        TerminalSurfaceFactory.makeOverride = { stub }
        XCTAssertTrue(TerminalSurfaceFactory.make() is SpySurface)
    }
}

final class TerminalCellMetricsTests: XCTestCase {
    private let metrics = TerminalCellMetrics(
        columns: 80, rows: 24, cellWidth: 8, cellHeight: 16, gridInset: 2)

    func test_theFirstRowStartsAtTheGridInsetNotAtZero() {
        XCTAssertEqual(metrics.rowFrame(0, width: 640), CGRect(x: 0, y: 2, width: 640, height: 16))
    }

    func test_eachRowIsOneCellFurtherDown() {
        XCTAssertEqual(metrics.rowFrame(3, width: 640).origin.y, 2 + 3 * 16)
        XCTAssertEqual(metrics.rowFrame(23, width: 640).origin.y, 2 + 23 * 16)
    }

    func test_aRowPastTheGridIsClampedIntoIt() {
        XCTAssertEqual(metrics.rowFrame(99, width: 640), metrics.rowFrame(23, width: 640))
        XCTAssertEqual(metrics.rowFrame(-4, width: 640), metrics.rowFrame(0, width: 640))
    }

    func test_theFirstColumnStartsAtTheGridInsetToo() {
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
        XCTAssertEqual(metrics.cellFrame(row: 0, columns: 0...999).maxX, 2 + 80 * 8)
        XCTAssertEqual(metrics.cellFrame(row: 0, columns: -5...2).origin.x, 2)
    }
}

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
