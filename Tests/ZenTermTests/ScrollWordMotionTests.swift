import XCTest

@testable import ZenTerm

/// Vim's `w`, `b` and `e` over a viewport.
///
/// A motion that lands one character out looks identical on screen to one that landed right; the
/// reader finds out when the yank hands them half a path. The rules are vim's, so there is a
/// correct answer to assert against.
final class ScrollWordMotionTests: XCTestCase {
    /// A fixture screen.
    private func screen(_ rows: [String]) -> ScrollWordMotion.Screen {
        ScrollWordMotion.Screen(lastRow: rows.count - 1) { row in
            rows.indices.contains(row) ? rows[row] : ""
        }
    }

    private func cell(_ row: Int, _ column: Int) -> ScrollCell {
        ScrollCell(row: row, column: column)
    }

    // MARK: classes

    func test_aRunOfPunctuationIsItsOwnWord() {
        // Treating punctuation as part of the word beside it is `W`'s behavior, not `w`'s.
        let sut = screen(["foo.bar"])

        XCTAssertEqual(ScrollWordMotion.nextWordStart(from: cell(0, 0), on: sut), cell(0, 3))
        XCTAssertEqual(ScrollWordMotion.nextWordStart(from: cell(0, 3), on: sut), cell(0, 4))
    }

    func test_underscoreAndDigitsCountAsWordCharacters() {
        let sut = screen(["run_2 next"])

        XCTAssertEqual(
            ScrollWordMotion.nextWordStart(from: cell(0, 0), on: sut), cell(0, 6),
            "run_2 is one word, so w crosses the whole of it")
    }

    // MARK: w

    func test_wLandsOnTheStartOfTheNextWord() {
        let sut = screen(["alpha beta gamma"])

        XCTAssertEqual(ScrollWordMotion.nextWordStart(from: cell(0, 0), on: sut), cell(0, 6))
        XCTAssertEqual(ScrollWordMotion.nextWordStart(from: cell(0, 6), on: sut), cell(0, 11))
    }

    func test_wFromInsideAWordStillReachesTheNextOne() {
        let sut = screen(["alpha beta"])

        XCTAssertEqual(ScrollWordMotion.nextWordStart(from: cell(0, 2), on: sut), cell(0, 6))
    }

    func test_wCrossesIntoTheNextRow() {
        let sut = screen(["one two", "three"])

        XCTAssertEqual(ScrollWordMotion.nextWordStart(from: cell(0, 4), on: sut), cell(1, 0))
    }

    func test_wSkipsBlankRowsBetweenBlocks() {
        let sut = screen(["one", "", "", "two"])

        XCTAssertEqual(ScrollWordMotion.nextWordStart(from: cell(0, 0), on: sut), cell(3, 0))
    }

    func test_wParksAtTheEndOfTheScreenRatherThanRunningOff() {
        let sut = screen(["one", ""])

        XCTAssertEqual(
            ScrollWordMotion.nextWordStart(from: cell(0, 0), on: sut), cell(1, 0),
            "the last cell reached, not a row past the grid")
    }

    // MARK: b

    func test_bGoesToTheStartOfTheWordTheCursorIsIn() {
        let sut = screen(["alpha beta"])

        XCTAssertEqual(ScrollWordMotion.previousWordStart(from: cell(0, 8), on: sut), cell(0, 6))
    }

    func test_bFromAWordStartGoesToThePreviousWord() {
        let sut = screen(["alpha beta"])

        XCTAssertEqual(ScrollWordMotion.previousWordStart(from: cell(0, 6), on: sut), cell(0, 0))
    }

    func test_bCrossesBackIntoTheRowAbove() {
        let sut = screen(["one two", "three"])

        XCTAssertEqual(ScrollWordMotion.previousWordStart(from: cell(1, 0), on: sut), cell(0, 4))
    }

    func test_bStopsAtTheTopOfTheScreen() {
        let sut = screen(["one"])

        XCTAssertEqual(ScrollWordMotion.previousWordStart(from: cell(0, 0), on: sut), cell(0, 0))
    }

    // MARK: e

    func test_eGoesToTheEndOfTheWordAhead() {
        let sut = screen(["alpha beta"])

        XCTAssertEqual(ScrollWordMotion.wordEnd(from: cell(0, 0), on: sut), cell(0, 4))
    }

    func test_eFromAWordEndGoesToTheNextWordsEnd() {
        let sut = screen(["alpha beta"])

        XCTAssertEqual(ScrollWordMotion.wordEnd(from: cell(0, 4), on: sut), cell(0, 9))
    }

    func test_eStopsOnPunctuationRatherThanSwallowingIt() {
        let sut = screen(["src/main.swift"])

        XCTAssertEqual(
            ScrollWordMotion.wordEnd(from: cell(0, 0), on: sut), cell(0, 2),
            "the end of `src`, with the slash its own word")
    }

    func test_eStopsAtTheEndOfTheScreen() {
        let sut = screen(["one"])

        XCTAssertEqual(ScrollWordMotion.wordEnd(from: cell(0, 2), on: sut), cell(0, 2))
    }
}
