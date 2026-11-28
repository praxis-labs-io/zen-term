import XCTest

@testable import ZenTerm

final class AgentPasteTests: XCTestCase {
    func test_shortTextIsOnePaste() {
        XCTAssertEqual(AgentPaste.pieces(of: "a\nb\nc", rows: 40), ["a\nb\nc"])
        XCTAssertEqual(AgentPaste.pieces(of: "one line", rows: 40), ["one line"])
    }

    func test_aPieceHoldsTwoNewlinesAtMost() {
        XCTAssertEqual(AgentPaste.pieces(of: "1\n2\n3\n4\n5", rows: 24), ["1\n2\n3", "\n4\n5"])
    }

    func test_aPaneUnderTwelveRowsTakesOneNewlinePerPiece() {
        XCTAssertEqual(AgentPaste.pieces(of: "1\n2\n3", rows: 11), ["1\n2", "\n3"])
        XCTAssertEqual(AgentPaste.pieces(of: "1\n2\n3", rows: 4), ["1\n2", "\n3"])
        XCTAssertEqual(AgentPaste.pieces(of: "1\n2\n3", rows: nil), ["1\n2\n3"])
    }

    func test_aCRLFCountsAsOneNewline() {
        XCTAssertEqual(AgentPaste.pieces(of: "1\r\n2\r\n3\r\n4", rows: 40), ["1\r\n2\r\n3", "\r\n4"])
    }

    func test_aLongLineSplitsAtTheLengthBudgetCountedInUTF16_neverInsideACharacter() {
        let line = String(repeating: "x", count: 799) + "😀" + "tail"
        let pieces = AgentPaste.pieces(of: line, rows: 40)

        XCTAssertEqual(pieces, [String(repeating: "x", count: 799), "😀tail"])
        XCTAssertEqual(AgentPaste.pieces(of: String(repeating: "y", count: 800), rows: 40).count, 1)
        XCTAssertEqual(AgentPaste.pieces(of: String(repeating: "y", count: 801), rows: 40).count, 2)
    }
}
