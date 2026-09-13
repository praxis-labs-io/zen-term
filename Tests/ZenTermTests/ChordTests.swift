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
        XCTAssertNil(Chord.parse("cmd+shift"))
        XCTAssertNil(Chord.parse("cmd+g+h"))
        XCTAssertNil(Chord.parse("hyper+g"))
        XCTAssertNil(Chord.parse("cmd++g"))
    }

    func test_parse_rejectsModifierlessAndMultiChar() {
        XCTAssertNil(Chord.parse("k"))
        XCTAssertNil(Chord.parse("cmd+space"))
        XCTAssertNotNil(Chord.parse("cmd+k"))
    }

    func test_displayGlyph_orderAndSymbols() {
        XCTAssertEqual(Chord(command: true, shift: true, key: "g").displayGlyph, "⌘⇧G")
        XCTAssertEqual(Chord(command: true, shift: true, option: true, control: true, key: "a").displayGlyph, "⌘⇧⌥⌃A")
        XCTAssertEqual(Chord(command: true, key: "-").displayGlyph, "⌘-")
        XCTAssertEqual(Chord(command: true, key: "\\").displayGlyph, "⌘\\")
        XCTAssertEqual(Chord(command: true, shift: true, key: "|").displayGlyph, "⌘⇧\\")
        XCTAssertEqual(Chord(command: true, shift: true, key: "_").displayGlyph, "⌘⇧-")
    }

    func test_modifierGlyph_ordersModifiersAndMatchesDisplayGlyph() {
        XCTAssertEqual(Chord.modifierGlyph(command: true, shift: true, option: false, control: false), "⌘⇧")
        XCTAssertEqual(Chord.modifierGlyph(command: true, shift: true, option: true, control: true), "⌘⇧⌥⌃")
        XCTAssertEqual(Chord.modifierGlyph(command: false, shift: false, option: false, control: false), "")
        XCTAssertEqual(Chord.modifierGlyph([.command, .control]), "⌘⌃")
        XCTAssertEqual(Chord.modifierGlyph([.shift, .option]), "⇧⌥")
    }

    func test_defaultTable_roundTripsThroughDisplay() {
        for chord in KeymapDefaults.map.keys {
            XCTAssertFalse(chord.displayGlyph.isEmpty)
        }
    }

    func test_shiftedGlyph_foldsOntoItsBaseKeyWithShift() {
        XCTAssertEqual(Chord(command: true, shift: true, key: "_"), Chord(command: true, shift: true, key: "-"))
        XCTAssertEqual(Chord.parse("cmd+shift+_"), Chord.parse("cmd+shift+-"))
        XCTAssertEqual(Chord.parse("cmd+shift+|"), Chord.parse("cmd+shift+\\"))
        XCTAssertEqual(Chord.parse("cmd+shift+!"), Chord.parse("cmd+shift+1"))
    }

    func test_shiftedGlyphWithoutShift_isLeftExactlyAsWritten() {
        let piped = Chord.parse("cmd+|")
        XCTAssertEqual(piped, Chord(command: true, key: "|"))
        XCTAssertFalse(piped!.shift)
    }

    func test_unshiftedGlyphOnANonUSLayout_isNotFoldedIntoAShiftedDefault() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
            context: nil, characters: "_", charactersIgnoringModifiers: "_", isARepeat: false, keyCode: 0)!
        let chord = Chord(event: event)
        XCTAssertEqual(chord, Chord(command: true, key: "_"))
        XCTAssertFalse(chord!.shift, "Shift must never be inferred from the glyph alone")
        XCTAssertNil(KeymapDefaults.map[chord!], "must not land on the ⌘⇧- split default")

        let plusEvent = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
            context: nil, characters: "+", charactersIgnoringModifiers: "+", isARepeat: false, keyCode: 0)!
        XCTAssertEqual(Chord(event: plusEvent), Chord(command: true, key: "+"))
    }

    func test_key_isLowercasedByInit_notJustByParse() {
        XCTAssertEqual(Chord(command: true, key: "G"), Chord(command: true, key: "g"))
        XCTAssertEqual(Chord(command: true, key: "G").key, "g")
        XCTAssertEqual(Chord(command: true, key: "G").displayGlyph, "⌘G")
        XCTAssertEqual(Chord(command: true, key: "G").configToken, "cmd+g")
    }

    func test_baseKeys_areLeftAlone() {
        let bare = Chord(command: true, key: "-")
        XCTAssertFalse(bare.shift)
        XCTAssertEqual(bare.configToken, "cmd+-")
        XCTAssertNotEqual(bare, Chord(command: true, shift: true, key: "-"))
        XCTAssertFalse(Chord(command: true, key: "g").shift)
    }

    func test_configToken_roundTripsWithParse() {
        let chords = [
            Chord(command: true, shift: true, key: "p"),
            Chord(command: true, key: ","),
            Chord(command: true, shift: true, key: "\\"),
            Chord(command: true, shift: true, key: "-"),
            Chord(option: true, control: true, key: "5"),
        ]
        for chord in chords {
            XCTAssertEqual(chord.configToken, expectedToken(chord))
            XCTAssertEqual(Chord.parse(chord.configToken), chord)
        }
    }

    func test_aKeyThatTypesNothing_readsAsAWordAndWritesBackAsOne() {
        XCTAssertEqual(Chord.parse("cmd+home"), Chord(command: true, key: "↖"))
        XCTAssertEqual(Chord.parse("cmd+page_down"), Chord(command: true, key: "⇟"))
        XCTAssertEqual(Chord(command: true, key: "↖").configToken, "cmd+home")
        XCTAssertEqual(Chord(command: true, key: "⇞").configToken, "cmd+page_up")
        XCTAssertEqual(Chord(command: true, key: "↖").displayGlyph, "⌘↖")
    }

    func test_ghosttysArrowSpelling_resolvesToTheSameChord() {
        XCTAssertEqual(Chord.parse("cmd+arrow_up"), Chord.parse("cmd+up"))
        XCTAssertEqual(Chord.parse("cmd+arrow_left"), Chord(command: true, key: "←"))
    }

    func test_everyShippedDefaultRoundTripsThroughItsConfigToken() {
        for (chord, _) in KeymapDefaults.map {
            XCTAssertEqual(Chord.parse(chord.configToken), chord, chord.configToken)
        }
    }

    func test_plusKey_roundTrips_shiftedAndUnshifted() {
        let shifted = Chord(command: true, shift: true, key: "+")
        XCTAssertEqual(shifted.key, "=")
        XCTAssertEqual(shifted.configToken, "cmd+shift+=")
        XCTAssertEqual(Chord.parse("cmd+shift+plus"), shifted)
        XCTAssertEqual(Chord.parse("cmd+shift+="), shifted)

        let bare = Chord(command: true, key: "+")
        XCTAssertEqual(bare.key, "+")
        XCTAssertEqual(bare.configToken, "cmd+plus")
        XCTAssertEqual(Chord.parse(bare.configToken), bare)
        XCTAssertNil(Chord.parse("cmd++"))
    }

    private func shiftedKeyDown(_ shiftedGlyph: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: shiftedGlyph,
            charactersIgnoringModifiers: shiftedGlyph, isARepeat: false, keyCode: 0)!
    }

    func test_liveShiftedEvent_resolvesToTheBindingSpelledWithTheBaseKey() {
        let plus = Chord(event: shiftedKeyDown("+"))
        XCTAssertEqual(plus, Chord(command: true, shift: true, key: "="))
        XCTAssertEqual(KeymapDefaults.map[plus!], .increaseFontSize)

        XCTAssertEqual(Chord(event: shiftedKeyDown("_")), Chord(command: true, shift: true, key: "-"))
        XCTAssertEqual(Chord(event: shiftedKeyDown("|")), Chord(command: true, shift: true, key: "\\"))
    }

    func test_liveUnshiftedMinus_isNotTheSplit() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
            context: nil, characters: "-", charactersIgnoringModifiers: "-", isARepeat: false, keyCode: 0)!
        let chord = Chord(event: event)
        XCTAssertEqual(chord, Chord(command: true, key: "-"))
        XCTAssertEqual(KeymapDefaults.map[chord!], .decreaseFontSize)
    }

    func test_liveShiftedEquals_isIncreaseFontSize() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: "+", charactersIgnoringModifiers: "+",
            isARepeat: false, keyCode: 24)!
        let chord = Chord(event: event)
        XCTAssertEqual(chord, Chord(command: true, shift: true, key: "="))
        XCTAssertEqual(KeymapDefaults.map[chord!], .increaseFontSize)
    }

    func test_configToken_arrowGlyph_roundTrips() {
        let up = Chord(command: true, key: "↑")
        XCTAssertEqual(up.configToken, "cmd+up")
        XCTAssertEqual(up.displayGlyph, "⌘↑")
        XCTAssertEqual(Chord.parse(up.configToken), up)
        XCTAssertEqual(Chord.parse("cmd+↑"), up)
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
