import XCTest

@testable import ZenTerm

final class ChordTests: XCTestCase {
    func test_parse_cmdShiftLetter() {
        let chord = Chord.parse("cmd+shift+g")
        XCTAssertEqual(chord, Chord(command: true, shift: true, key: "g"))
    }

    func test_parse_aliases_areCaseInsensitive() {
        XCTAssertEqual(Chord.parse("Command+Alt+Control+G"), Chord.parse("cmd+opt+ctrl+g"))
        XCTAssertEqual(Chord.parse("cmd+option+f"), Chord(command: true, option: true, key: "f"))
    }

    func test_parse_rejectsMalformed() {
        XCTAssertNil(Chord.parse("cmd+shift"))  // no key token
        XCTAssertNil(Chord.parse("cmd+g+h"))  // two key tokens
        XCTAssertNil(Chord.parse("hyper+g"))  // unknown modifier
        XCTAssertNil(Chord.parse("cmd++g"))  // empty token
    }

    func test_parse_rejectsModifierlessAndMultiChar() {
        XCTAssertNil(Chord.parse("k"))  // no modifier — would swallow the plain keystroke
        XCTAssertNil(Chord.parse("cmd+space"))  // multi-char key never matches a live event
        XCTAssertNotNil(Chord.parse("cmd+k"))  // control: a valid single-char modified chord
    }

    func test_displayGlyph_orderAndSymbols() {
        XCTAssertEqual(Chord(command: true, shift: true, key: "g").displayGlyph, "⌘⇧G")
        XCTAssertEqual(Chord(command: true, shift: true, option: true, control: true, key: "a").displayGlyph, "⌘⇧⌥⌃A")
        XCTAssertEqual(Chord(command: true, key: "-").displayGlyph, "⌘-")
        XCTAssertEqual(Chord(command: true, shift: true, key: "|").displayGlyph, "⌘⇧|")
        XCTAssertEqual(Chord(command: true, key: "\\").displayGlyph, "⌘\\")
    }

    func test_defaultTable_roundTripsThroughDisplay() {
        // Every default chord produces a non-empty glyph and re-reads its key stably.
        for chord in KeymapDefaults.map.keys {
            XCTAssertFalse(chord.displayGlyph.isEmpty)
        }
    }
}
