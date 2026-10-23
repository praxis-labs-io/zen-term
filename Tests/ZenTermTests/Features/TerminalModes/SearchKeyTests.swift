import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

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
        XCTAssertEqual(decode(try keyDown("N", unshifted: "N")), .step(.next))
    }

    func test_commandAndOptionChordsFallThrough() throws {
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

final class SearchMatchCellTests: XCTestCase {
    private let rows = [
        "the first error line",
        "nothing here",
        "another error follows",
        "quiet",
        "trailing error",
    ]

    private func cell(
        _ needle: String, from cursor: ScrollCell, _ step: TerminalSearchStep, rows: [String]? = nil,
        viewportMoved: Bool = false, selected: Int? = nil, total: Int? = nil
    ) -> ScrollCell? {
        SearchController.matchCell(
            needle: needle, rows: rows ?? self.rows, from: cursor, step: step,
            viewportMoved: viewportMoved, selected: selected, total: total)
    }

    func test_nextTakesTheNearestMatchAboveTheCursor() {
        XCTAssertEqual(cell("error", from: ScrollCell(row: 4, column: 9), .next), ScrollCell(row: 2, column: 8))
    }

    func test_previousTakesTheNearestMatchBelowTheCursor() {
        XCTAssertEqual(cell("error", from: ScrollCell(row: 0, column: 10), .previous), ScrollCell(row: 2, column: 8))
    }

    func test_nothingInThatDirectionFallsBackToTheTopRow() {
        XCTAssertEqual(cell("error", from: ScrollCell(row: 0, column: 0), .next), ScrollCell(row: 0, column: 10))
    }

    func test_theCursorsOwnCellIsNeverTheAnswer() {
        let landed = cell("error", from: ScrollCell(row: 2, column: 8), .previous)
        XCTAssertNotEqual(landed, ScrollCell(row: 2, column: 8))
        XCTAssertEqual(landed, ScrollCell(row: 4, column: 9))
    }

    func test_caseIsFoldedTheWayTheEngineFoldsIt() {
        XCTAssertEqual(cell("ERROR", from: ScrollCell(row: 4, column: 9), .next), ScrollCell(row: 2, column: 8))
    }

    func test_severalOnOneRowAreSeparateCandidates() {
        let repeated = ["error and error again"]
        XCTAssertEqual(
            cell("error", from: ScrollCell(row: 0, column: 20), .next, rows: repeated),
            ScrollCell(row: 0, column: 10))
    }

    func test_aRowHoldingTwoMatchesStepsThroughBothBeforeLeavingIt() {
        let twoPerRow = ["error one error two", "quiet", "error three error four"]
        XCTAssertEqual(
            cell("error", from: ScrollCell(row: 2, column: 12), .next, rows: twoPerRow),
            ScrollCell(row: 2, column: 0))
        XCTAssertEqual(
            cell("error", from: ScrollCell(row: 2, column: 0), .next, rows: twoPerRow),
            ScrollCell(row: 0, column: 10))
    }

    func test_aStepThatScrolledTakesTheParkedRowNotTheStaleCursor() {
        let scrolledRows = ["error at top", "", "error lower down"]
        XCTAssertEqual(
            cell(
                "error", from: ScrollCell(row: 2, column: 0), .next, rows: scrolledRows,
                viewportMoved: true),
            ScrollCell(row: 0, column: 0),
            "a scroll parks the match's own row at the top")
    }

    func test_aScrollClampedAtTheLiveEndTakesTheLastMatchNotTheFirst() {
        let clamped = ["line 100", "error above", "error selected", "", "a prompt"]
        XCTAssertEqual(
            cell(
                "error", from: ScrollCell(row: 0, column: 0), .previous, rows: clamped,
                viewportMoved: true, selected: 0, total: 9),
            ScrollCell(row: 2, column: 0),
            "the newest match is the bottom-most on a screen clamped at the live end")
    }

    func test_aClampedScreenHoldingSeveralCandidatesIsCountedNotGuessed() {
        let clamped = ["line 100", "error selected", "error newer", "error newest", "a prompt"]
        XCTAssertEqual(
            cell(
                "error", from: ScrollCell(row: 0, column: 0), .previous, rows: clamped,
                viewportMoved: true, selected: 2, total: 9),
            ScrollCell(row: 1, column: 0),
            "two newer matches below it puts the selected one two up from the bottom")
    }

    func test_aScrollClampedAtTheTopCountsDownFromTheOldest() {
        let clamped = ["line 1", "error oldest", "error selected", "quiet", "error newer"]
        XCTAssertEqual(
            cell(
                "error", from: ScrollCell(row: 4, column: 0), .next, rows: clamped,
                viewportMoved: true, selected: 1, total: 3),
            ScrollCell(row: 2, column: 0),
            "one older match above it puts the selected one one down from the first")
    }

    func test_aCountThatDoesNotLandOnScreenDoesNotGuess() {
        let clamped = ["line 100", "error one", "error two", "a prompt"]
        XCTAssertEqual(
            cell(
                "error", from: ScrollCell(row: 0, column: 0), .previous, rows: clamped,
                viewportMoved: true, selected: 7, total: 9),
            ScrollCell(row: 2, column: 0),
            "the direction's end of the screen, as before")
    }

    func test_aStepThatDidNotScrollStillFollowsItsDirectionAtTheEnds() {
        let ends = ["error above", "quiet", "error below"]
        XCTAssertEqual(
            cell("error", from: ScrollCell(row: 2, column: 5), .previous, rows: ends),
            ScrollCell(row: 2, column: 0),
            "nothing further down, so not the top of the screen")
    }

    func test_noOccurrenceLeavesTheCursorAlone() {
        XCTAssertNil(cell("absent", from: ScrollCell(row: 2, column: 0), .next))
        XCTAssertNil(cell("", from: ScrollCell(row: 2, column: 0), .next))
    }
}
