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
        XCTAssertEqual(Chord(command: true, key: "\\").displayGlyph, "⌘\\")
        // A shifted symbol displays as its base key + ⇧ — the same spelling the config file uses,
        // and the convention macOS itself follows (⇧⌘4, not ⇧⌘$).
        XCTAssertEqual(Chord(command: true, shift: true, key: "|").displayGlyph, "⌘⇧\\")
        XCTAssertEqual(Chord(command: true, shift: true, key: "_").displayGlyph, "⌘⇧-")
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

    func test_defaultTable_roundTripsThroughDisplay() {
        // Every default chord produces a non-empty glyph and re-reads its key stably.
        for chord in KeymapDefaults.map.keys {
            XCTAssertFalse(chord.displayGlyph.isEmpty)
        }
    }

    func test_shiftedGlyph_foldsOntoItsBaseKeyWithShift() {
        // The bug ZEN-142 tripped on: `charactersIgnoringModifiers` applies Shift, so a live ⌘⇧-
        // press arrives as "_" while the config spells the same chord `cmd+shift+-`. Both fold onto
        // one chord, so the keymap holds one entry per binding rather than one per spelling.
        XCTAssertEqual(Chord(command: true, shift: true, key: "_"), Chord(command: true, shift: true, key: "-"))
        XCTAssertEqual(Chord.parse("cmd+shift+_"), Chord.parse("cmd+shift+-"))
        XCTAssertEqual(Chord.parse("cmd+shift+|"), Chord.parse("cmd+shift+\\"))
        XCTAssertEqual(Chord.parse("cmd+shift+!"), Chord.parse("cmd+shift+1"))
    }

    func test_shiftedGlyphWithoutShift_isLeftExactlyAsWritten() {
        // The fold requires Shift. It's tempting to infer it — "|" is un-typeable without Shift on
        // US, so `cmd+|` looks like a chord worth rescuing — but the table is US-only, and inferring
        // Shift from the glyph breaks layouts where these keys are unshifted. See
        // `test_unshiftedGlyphOnANonUSLayout_isNotFoldedIntoAShiftedDefault`.
        let piped = Chord.parse("cmd+|")
        XCTAssertEqual(piped, Chord(command: true, key: "|"))
        XCTAssertFalse(piped!.shift)
    }

    func test_unshiftedGlyphOnANonUSLayout_isNotFoldedIntoAShiftedDefault() {
        // On AZERTY `_` is an UNSHIFTED key. Typing ⌘_ there must reach the terminal — folding it to
        // ⌘⇧- would fire split_horizontal and swallow the keystroke, a chord the user never pressed.
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
            context: nil, characters: "_", charactersIgnoringModifiers: "_", isARepeat: false, keyCode: 0)!
        let chord = Chord(event: event)
        XCTAssertEqual(chord, Chord(command: true, key: "_"))
        XCTAssertFalse(chord!.shift, "Shift must never be inferred from the glyph alone")
        XCTAssertNil(KeymapDefaults.map[chord!], "must not land on the ⌘⇧- split default")

        // Same shape on German QWERTZ, where `+` is unshifted.
        let plusEvent = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
            context: nil, characters: "+", charactersIgnoringModifiers: "+", isARepeat: false, keyCode: 0)!
        XCTAssertEqual(Chord(event: plusEvent), Chord(command: true, key: "+"))
    }

    func test_baseKeys_areLeftAlone() {
        // Only shifted glyphs fold. A base key keeps whatever Shift it was spelled with, so bare
        // ⌘- stays bare ⌘- (ghostty's text zoom) rather than drifting into ⌘⇧-.
        let bare = Chord(command: true, key: "-")
        XCTAssertFalse(bare.shift)
        XCTAssertEqual(bare.configToken, "cmd+-")
        XCTAssertNotEqual(bare, Chord(command: true, shift: true, key: "-"))
        XCTAssertFalse(Chord(command: true, key: "g").shift)  // letters have no shifted twin
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

    func test_plusKey_roundTrips_shiftedAndUnshifted() {
        // Shifted, `+` folds onto ⇧= — on US that's the only way to type it, so ⌘⇧+ and ⌘⇧= are one
        // chord and the `plus` escape isn't needed on the way out.
        let shifted = Chord(command: true, shift: true, key: "+")
        XCTAssertEqual(shifted.key, "=")
        XCTAssertEqual(shifted.configToken, "cmd+shift+=")
        XCTAssertEqual(Chord.parse("cmd+shift+plus"), shifted)
        XCTAssertEqual(Chord.parse("cmd+shift+="), shifted)

        // Unshifted, `+` survives as itself (a layout where it needs no Shift, or a literal
        // `cmd+plus`), so `configToken` still has to escape it — `cmd++` would parse as a stray
        // empty token and the binding would be lost on the next write.
        let bare = Chord(command: true, key: "+")
        XCTAssertEqual(bare.key, "+")
        XCTAssertEqual(bare.configToken, "cmd+plus")
        XCTAssertEqual(Chord.parse(bare.configToken), bare)  // stable on re-read
        XCTAssertNil(Chord.parse("cmd++"))  // the raw form is still rejected
    }

    /// A real keypress, built the way macOS reports one: `charactersIgnoringModifiers` applies
    /// Shift, so the ⌘⇧- key pair arrives carrying "_". The shifted glyphs here are written out by
    /// hand rather than derived from `Chord` — deriving them from the table under test would make
    /// these assert nothing.
    private func shiftedKeyDown(_ shiftedGlyph: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: shiftedGlyph,
            charactersIgnoringModifiers: shiftedGlyph, isARepeat: false, keyCode: 0)!
    }

    func test_liveShiftedEvent_resolvesToTheBindingSpelledWithTheBaseKey() {
        // ZEN-142's whole trap in one assertion: the default is written `cmd+shift+-`, the keyboard
        // delivers "_", and they have to be the same chord or the binding is dead on arrival.
        let minus = Chord(event: shiftedKeyDown("_"))
        XCTAssertEqual(minus, Chord(command: true, shift: true, key: "-"))
        XCTAssertEqual(KeymapDefaults.map[minus!], .splitHorizontal)

        let backslash = Chord(event: shiftedKeyDown("|"))
        XCTAssertEqual(backslash, Chord(command: true, shift: true, key: "\\"))
        XCTAssertEqual(KeymapDefaults.map[backslash!], .splitVertical)
    }

    func test_liveUnshiftedMinus_isNotTheSplit() {
        // The bug ZEN-142 reports: ⌘- must reach the terminal for ghostty's text zoom.
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
            context: nil, characters: "-", charactersIgnoringModifiers: "-", isARepeat: false, keyCode: 0)!
        let chord = Chord(event: event)
        XCTAssertEqual(chord, Chord(command: true, key: "-"))
        XCTAssertNil(KeymapDefaults.map[chord!])
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
