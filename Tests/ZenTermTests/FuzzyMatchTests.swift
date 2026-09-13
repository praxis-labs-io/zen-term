import XCTest

@testable import ZenTerm

final class FuzzyMatchTests: XCTestCase {
    func test_emptyQuery_matchesWithZeroScore() {
        XCTAssertEqual(FuzzyMatch.score("", "Anything"), 0)
    }

    func test_nonSubsequence_returnsNil() {
        XCTAssertNil(FuzzyMatch.score("xyz", "New Tab"))
        XCTAssertNil(FuzzyMatch.score("tabb", "New Tab"))
    }

    func test_subsequence_matches() {
        XCTAssertNotNil(FuzzyMatch.score("nt", "New Tab"))
        XCTAssertNotNil(FuzzyMatch.score("tab", "New Tab"))
    }

    func test_caseInsensitive() {
        XCTAssertNotNil(FuzzyMatch.score("TAB", "new tab"))
    }

    func test_wordBoundaryBeatsMidWord() {
        let boundary = FuzzyMatch.score("tab", "New Tab")
        let midWord = FuzzyMatch.score("tab", "Untabbed Stuff")
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(midWord)
        XCTAssertGreaterThan(boundary!, midWord!)
    }

    func test_earlierFirstMatchWinsTie() {
        let early = FuzzyMatch.score("tab", "New Tab")!
        let late = FuzzyMatch.score("tab", "Previous Tab")!
        XCTAssertGreaterThan(early, late)
    }

    func test_firstCharAtIndexZero_noSpuriousContiguityBonus() {
        XCTAssertEqual(FuzzyMatch.score("s", "Split"), 9)
    }

    func test_contiguousBeatsScattered() {
        let contiguous = FuzzyMatch.score("res", "Resize Pane Left")!
        let scattered = FuzzyMatch.score("res", "Right Side Escape")!
        XCTAssertGreaterThan(contiguous, scattered)
    }
}
