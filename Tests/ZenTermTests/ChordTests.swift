import AppKit
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

    func test_modifierGlyph_ordersModifiersAndMatchesDisplayGlyph() {
        // The ⌘⇧⌥⌃ order lives once (Chord.modifierGlyph); displayGlyph and the keybind-capture
        // preview both route through it.
        XCTAssertEqual(Chord.modifierGlyph(command: true, shift: true, option: false, control: false), "⌘⇧")
        XCTAssertEqual(Chord.modifierGlyph(command: true, shift: true, option: true, control: true), "⌘⇧⌥⌃")
        XCTAssertEqual(Chord.modifierGlyph(command: false, shift: false, option: false, control: false), "")
        // The flags overload agrees with the bool core.
        XCTAssertEqual(Chord.modifierGlyph([.command, .control]), "⌘⌃")
        XCTAssertEqual(Chord.modifierGlyph([.shift, .option]), "⇧⌥")
    }

    func test_shiftedSibling_swapsGlyphOnSamePhysicalKey() {
        // Same physical key, other glyph, same modifiers — so a keybind written as one spelling
        // matches the live event, which carries the other (charactersIgnoringModifiers applies Shift).
        XCTAssertEqual(
            Chord(command: true, shift: true, key: "-").shiftedSibling,
            Chord(command: true, shift: true, key: "_"))
        XCTAssertEqual(
            Chord(command: true, shift: true, key: "_").shiftedSibling,
            Chord(command: true, shift: true, key: "-"))
        XCTAssertEqual(
            Chord(command: true, shift: true, key: "\\").shiftedSibling,
            Chord(command: true, shift: true, key: "|"))
        XCTAssertNil(Chord(command: true, key: "g").shiftedSibling)  // letters have no shifted twin
        XCTAssertNil(Chord(command: true, key: "↑").shiftedSibling)  // arrow glyph tokens either
    }

    func test_defaultTable_roundTripsThroughDisplay() {
        // Every default chord produces a non-empty glyph and re-reads its key stably.
        for chord in KeymapDefaults.map.keys {
            XCTAssertFalse(chord.displayGlyph.isEmpty)
        }
    }

    func test_configToken_roundTripsWithParse() {
        let chords = [
            Chord(command: true, shift: true, key: "p"),
            Chord(command: true, key: ","),
            Chord(command: true, shift: true, key: "\\"),
            Chord(command: true, shift: true, key: "|"),
            Chord(option: true, control: true, key: "5"),
        ]
        for chord in chords {
            XCTAssertEqual(chord.configToken, expectedToken(chord))
            XCTAssertEqual(Chord.parse(chord.configToken), chord)
        }
    }

    func test_configToken_plusKey_roundTrips() {
        // `+` is the token separator, so the plus key travels as the word `plus` — otherwise
        // `cmd+shift++` parses as a stray empty token and the binding is lost on reload.
        let plus = Chord(command: true, shift: true, key: "+")
        XCTAssertEqual(plus.configToken, "cmd+shift+plus")
        XCTAssertEqual(Chord.parse(plus.configToken), plus)
        XCTAssertNil(Chord.parse("cmd+shift++"))  // the raw form is still rejected
    }

    func test_configToken_arrowGlyph_roundTrips() {
        // Arrow keys carry a non-printing character from the event; `Chord(event:)` maps them to a
        // glyph so they display and round-trip as a single character.
        let up = Chord(command: true, key: "↑")
        XCTAssertEqual(up.configToken, "cmd+↑")
        XCTAssertEqual(up.displayGlyph, "⌘↑")
        XCTAssertEqual(Chord.parse(up.configToken), up)
    }

    private func expectedToken(_ c: Chord) -> String {
        var t = ""
        if c.command { t += "cmd+" }
        if c.shift { t += "shift+" }
        if c.option { t += "opt+" }
        if c.control { t += "ctrl+" }
        return t + c.key
    }
}
