import XCTest

@testable import ZenTerm

/// Vim's `w`, `b` and `e` over a viewport (ZEN-331).
///
/// Every one of these is a silent failure on screen: a motion that lands one character out looks
/// identical to one that landed right, and the reader only finds out when the yank hands them
/// half a path. The rules are vim's, so they have a correct answer to assert against.
final class ScrollWordMotionTests: XCTestCase {
    /// A fixture screen. `w` on the last row has nowhere to go, which is a case the motions have
    /// to survive rather than run off.
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
        // `foo.bar` is three words in vim, not two: a class change starts a word with no blank
        // between. Treating punctuation as part of the word beside it makes `w` skip the dot and
        // land on `bar`, which is `W`'s behavior, not `w`'s.
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
        // A row's text ends where its characters do; the columns past it are not cells to land on.
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
