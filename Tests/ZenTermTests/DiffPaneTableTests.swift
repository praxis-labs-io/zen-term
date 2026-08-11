import AppKit
import XCTest

@testable import ZenTerm

/// Pure, window-free bits of the side-by-side pane. `halfPageDirection` is the guard that
/// keeps Ctrl-D as terminal EOF (only D/U with *exactly* Control half-page) — a silent regression here
/// (a flipped keyCode, or matching against `deviceIndependentFlagsMask` so ⌘⌃D leaks through, the
/// same reorder trap) has no on-screen tell, so it earns a test.
final class DiffPaneTableTests: XCTestCase {
    private func keyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
    }

    func test_ctrlD_isHalfPageDown_ctrlU_isUp() throws {
        XCTAssertEqual(DiffPaneTable.halfPageDirection(for: try keyDown(keyCode: 2, flags: .control)), 1)
        XCTAssertEqual(DiffPaneTable.halfPageDirection(for: try keyDown(keyCode: 32, flags: .control)), -1)
    }

    func test_requiresExactlyControl_soItDoesntStealFromOtherChords() throws {
        // Any extra reservable modifier means it's a different chord (and Ctrl-D alone stays EOF).
        XCTAssertNil(DiffPaneTable.halfPageDirection(for: try keyDown(keyCode: 2, flags: [.command, .control])))
        XCTAssertNil(DiffPaneTable.halfPageDirection(for: try keyDown(keyCode: 2, flags: [.shift, .control])))
        XCTAssertNil(DiffPaneTable.halfPageDirection(for: try keyDown(keyCode: 2, flags: [.option, .control])))
        XCTAssertNil(DiffPaneTable.halfPageDirection(for: try keyDown(keyCode: 2, flags: [])))
    }

    func test_toleratesNonReservableBits() throws {
        // AppKit stamps .function / .numericPad onto events; matching the reservable set (not the raw
        // mask) must still read this as Control-only.
        let event = try keyDown(keyCode: 2, flags: [.control, .function])
        XCTAssertEqual(DiffPaneTable.halfPageDirection(for: event), 1)
    }

    func test_ignoresOtherKeys() throws {
        XCTAssertNil(DiffPaneTable.halfPageDirection(for: try keyDown(keyCode: 123, flags: [])))  // ←
        XCTAssertNil(DiffPaneTable.halfPageDirection(for: try keyDown(keyCode: 125, flags: .control)))  // ⌃↓
        XCTAssertNil(DiffPaneTable.halfPageDirection(for: try keyDown(keyCode: 8, flags: .control)))  // ⌃C
    }

    func test_columnWidth_clampsToZeroWhenGuttersExceedTotal_andGrowsWithWidth() {
        let gutter = DiffCellMetrics.nominalGutterWidth
        XCTAssertEqual(DiffLineCell.columnWidth(forTotalWidth: 10, gutterWidth: gutter), 0)
        XCTAssertGreaterThan(
            DiffLineCell.columnWidth(forTotalWidth: 600, gutterWidth: gutter),
            DiffLineCell.columnWidth(forTotalWidth: 300, gutterWidth: gutter))
    }
}
