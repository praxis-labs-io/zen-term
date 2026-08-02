import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// The find bar's phase-two key decoder (ZEN-324), and the viewport scan that decides where the
/// cursor lands.
///
/// Both fail silently. A key the decoder wrongly claims is one the shell never sees; a key it
/// wrongly drops is an `n` that does nothing. And a scan that picks the wrong occurrence puts the
/// cursor on text the reader was not looking for, which reads as the mode being broken rather than
/// as an approximation.
final class SearchKeyTests: XCTestCase {
    private func keyDown(
        _ characters: String, unshifted: String? = nil, flags: NSEvent.ModifierFlags = [],
        keyCode: UInt16 = 0
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters,
                charactersIgnoringModifiers: unshifted ?? characters, isARepeat: false, keyCode: keyCode))
    }

    private func decode(_ event: NSEvent) -> SearchController.Key? {
        SearchController.key(for: event)
    }

    // MARK: stepping

    func test_nStepsForwardAndShiftNBack() throws {
        XCTAssertEqual(decode(try keyDown("n")), .step(.next))
        XCTAssertEqual(decode(try keyDown("N", unshifted: "n", flags: .shift)), .step(.previous))
    }

    func test_returnMirrorsNAndKeypadEnterCountsToo() throws {
        XCTAssertEqual(decode(try keyDown("\r", keyCode: 36)), .step(.next))
        XCTAssertEqual(decode(try keyDown("\r", flags: .shift, keyCode: 36)), .step(.previous))
        XCTAssertEqual(decode(try keyDown("\r", keyCode: 76)), .step(.next))
    }

    func test_escapeEndsTheSearch() throws {
        XCTAssertEqual(decode(try keyDown("\u{1b}", keyCode: 53)), .end)
    }

    func test_shiftednessComesFromTheFlagsNotTheCharacterCase() throws {
        // Caps Lock uppercases the character without setting .shift. Reading the case would turn
        // every `n` into an `N` for as long as it was on.
        XCTAssertEqual(decode(try keyDown("N", unshifted: "N")), .step(.next))
    }

    // MARK: what it must NOT claim

    func test_commandAndOptionChordsFallThrough() throws {
        // The one that matters. `KeyInterceptor` is a local monitor running ahead of menu key
        // equivalents, so claiming these kills ⌘N, ⌘W and ⌘Q for as long as the bar is up.
        XCTAssertNil(decode(try keyDown("n", flags: .command)))
        XCTAssertNil(decode(try keyDown("n", flags: [.command, .shift])))
        XCTAssertNil(decode(try keyDown("w", flags: .command)))
        XCTAssertNil(decode(try keyDown("n", flags: .option)))
    }

    func test_unmappedKeysDecodeToNothing() throws {
        XCTAssertNil(decode(try keyDown("j")))
        XCTAssertNil(decode(try keyDown("x")))
        XCTAssertNil(decode(try keyDown("n", flags: .control)))
    }
}

/// Where the cursor lands after a step. See `SearchController.matchCell` for why this is inference
/// rather than a lookup.
final class SearchMatchCellTests: XCTestCase {
    private let rows = [
        "the first error line",  // 0
        "nothing here",  // 1
        "another error follows",  // 2
        "quiet",  // 3
        "trailing error",  // 4
    ]

    private func cell(
        _ needle: String, from cursor: ScrollCell, _ step: TerminalSearchStep, rows: [String]? = nil,
        scrolled: Bool = false
    ) -> ScrollCell? {
        SearchController.matchCell(
            needle: needle, rows: rows ?? self.rows, from: cursor, step: step, scrolled: scrolled)
    }

    func test_nextTakesTheNearestMatchAboveTheCursor() {
        // libghostty walks matches newest to oldest, so `next` moves up the screen.
        XCTAssertEqual(cell("error", from: ScrollCell(row: 4, column: 9), .next), ScrollCell(row: 2, column: 8))
    }

    func test_previousTakesTheNearestMatchBelowTheCursor() {
        XCTAssertEqual(cell("error", from: ScrollCell(row: 0, column: 10), .previous), ScrollCell(row: 2, column: 8))
    }

    func test_nothingInThatDirectionFallsBackToTheTopRow() {
        // Nothing above means the backend had to scroll to reach the match, and a scroll parks the
        // match's own row at the top of the viewport.
        XCTAssertEqual(cell("error", from: ScrollCell(row: 0, column: 0), .next), ScrollCell(row: 0, column: 10))
    }

    func test_theCursorsOwnCellIsNeverTheAnswer() {
        // Otherwise a `previous` onto the cell already under the cursor reads as a dead key.
        let landed = cell("error", from: ScrollCell(row: 2, column: 8), .previous)
        XCTAssertNotEqual(landed, ScrollCell(row: 2, column: 8))
        XCTAssertEqual(landed, ScrollCell(row: 4, column: 9))
    }

    func test_caseIsFoldedTheWayTheEngineFoldsIt() {
        // The engine matches with std.ascii.indexOfIgnoreCase, so the scan has to agree or it finds
        // nothing where the highlight clearly shows something.
        XCTAssertEqual(cell("ERROR", from: ScrollCell(row: 4, column: 9), .next), ScrollCell(row: 2, column: 8))
    }

    func test_severalOnOneRowAreSeparateCandidates() {
        let repeated = ["error and error again"]
        XCTAssertEqual(
            cell("error", from: ScrollCell(row: 0, column: 20), .next, rows: repeated),
            ScrollCell(row: 0, column: 10))
    }

    func test_aRowHoldingTwoMatchesStepsThroughBothBeforeLeavingIt() {
        // Found at the machine. Nearest-by-distance took the closer column on the row above rather
        // than the one the engine stopped on, and the cursor drifted off the selected line. The
        // engine steps in strict buffer order, so the answer is the immediate neighbour in it.
        let twoPerRow = ["error one error two", "quiet", "error three error four"]
        // Starting at the last match on the bottom row, `next` walks back through that row first.
        XCTAssertEqual(
            cell("error", from: ScrollCell(row: 2, column: 12), .next, rows: twoPerRow),
            ScrollCell(row: 2, column: 0))
        // Only then up, and onto the *rightmost* match of the row above, which is the newer of the
        // two and therefore the one the engine reaches next.
        XCTAssertEqual(
            cell("error", from: ScrollCell(row: 2, column: 0), .next, rows: twoPerRow),
            ScrollCell(row: 0, column: 10))
    }

    func test_aStepThatScrolledTakesTheParkedRowNotTheStaleCursor() {
        // Once the viewport moves, the cursor names a row that no longer exists. A direction scan
        // from it walks to whatever sits near the stale row, and the error compounds over a run.
        let scrolledRows = ["error at top", "", "error lower down"]
        XCTAssertEqual(
            cell("error", from: ScrollCell(row: 2, column: 0), .next, rows: scrolledRows, scrolled: true),
            ScrollCell(row: 0, column: 0),
            "a scroll parks the match's own row at the top")
    }

    func test_noOccurrenceLeavesTheCursorAlone() {
        XCTAssertNil(cell("absent", from: ScrollCell(row: 2, column: 0), .next))
        XCTAssertNil(cell("", from: ScrollCell(row: 2, column: 0), .next))
    }
}
