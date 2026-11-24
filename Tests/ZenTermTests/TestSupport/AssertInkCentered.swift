import AppKit
import XCTest

@testable import ZenTerm

// Measured from where the labels land, not from the row's trim, so a missing or wrong trim shows as lopsided padding.
@MainActor
func assertInkCentered(_ row: ListRow, file: StaticString = #filePath, line: UInt = #line) throws {
    row.window?.layoutIfNeeded()
    let title = row.titleLabelForTesting
    let subtitle = try XCTUnwrap(row.subtitleLineForTesting, "the row has no subtitle", file: file, line: line)
    let titleFrame = row.convert(title.bounds, from: title)
    let subtitleFrame = row.convert(subtitle.bounds, from: subtitle)
    let titleTop = row.isFlipped ? titleFrame.minY : row.bounds.maxY - titleFrame.maxY
    let subtitleBottom = row.isFlipped ? row.bounds.maxY - subtitleFrame.maxY : subtitleFrame.minY
    let baselineAboveBottom = subtitleBottom + subtitle.lastBaselineOffsetFromBottom
    let halfPixel = 0.5 / (row.window?.backingScaleFactor ?? 2)
    XCTAssertEqual(
        baselineAboveBottom, titleTop, accuracy: halfPixel,
        "the subtitle's baseline sits as far above the row's bottom as the title sits below its top",
        file: file, line: line)
}
