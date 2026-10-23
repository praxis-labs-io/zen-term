import AppKit
import XCTest

@testable import ZenTerm

final class KeyboardLayoutTests: XCTestCase {
    override func tearDown() {
        KeyboardLayout.layoutOverrideForTesting = nil
        super.tearDown()
    }

    func test_shiftedGlyphWithoutShift_isNotTypeableWhenTheLayoutNeedsShiftForIt() {
        KeyboardLayout.layoutOverrideForTesting = { shift in shift ? [42: "|"] : [42: "\\"] }
        XCTAssertFalse(KeyboardLayout.canType(Chord(command: true, key: "|")))
    }

    func test_theSameGlyphIsTypeableWhenTheLayoutProducesItUnshifted() {
        KeyboardLayout.layoutOverrideForTesting = { shift in shift ? [22: "6"] : [22: "_"] }
        XCTAssertTrue(KeyboardLayout.canType(Chord(command: true, key: "_")))
    }

    func test_canType_comparesThroughTheFold_soAShiftedChordMatchesItsShiftedGlyph() {
        KeyboardLayout.layoutOverrideForTesting = { shift in shift ? [27: "_"] : [27: "-"] }
        XCTAssertTrue(KeyboardLayout.canType(Chord(command: true, shift: true, key: "-")))
    }

    func test_specialKeyGlyphs_bypassTheLayout() {
        KeyboardLayout.layoutOverrideForTesting = { _ in [:] }
        for glyph in ["←", "→", "↑", "↓", "⏎", "↖", "↘", "⇞", "⇟"] {
            XCTAssertTrue(KeyboardLayout.canType(Chord(command: true, key: glyph)), glyph)
        }
    }

    func test_specialKeyGlyphs_resolveToTheirPhysicalKey() {
        KeyboardLayout.layoutOverrideForTesting = { _ in [:] }
        XCTAssertEqual(KeyboardLayout.keyCode(for: Chord(command: true, key: "↖")), 115)
        XCTAssertEqual(KeyboardLayout.keyCode(for: Chord(command: true, key: "↘")), 119)
        XCTAssertEqual(KeyboardLayout.keyCode(for: Chord(command: true, key: "⇞")), 116)
        XCTAssertEqual(KeyboardLayout.keyCode(for: Chord(command: true, key: "⇟")), 121)
    }

    func test_keyCodeFor_findsTheKeyThatTypesTheGlyph() {
        KeyboardLayout.layoutOverrideForTesting = { shift in shift ? [42: "|"] : [42: "\\"] }
        XCTAssertEqual(KeyboardLayout.keyCode(for: Chord(command: true, key: "\\")), 42)
    }

    func test_keyCodeFor_resolvesAShiftedChordThroughTheFold() {
        KeyboardLayout.layoutOverrideForTesting = { shift in shift ? [27: "_"] : [27: "-"] }
        XCTAssertEqual(KeyboardLayout.keyCode(for: Chord(command: true, shift: true, key: "-")), 27)
    }

    func test_keyCodeFor_isNilWhenNoKeyTypesIt() {
        KeyboardLayout.layoutOverrideForTesting = { shift in shift ? [42: "|"] : [42: "\\"] }
        XCTAssertNil(
            KeyboardLayout.keyCode(for: Chord(command: true, key: "|")),
            "`|` needs Shift on this layout, so no unshifted key types it")
    }

    func test_keyCodeFor_takesTheLowestKeyWhenALayoutRepeatsAGlyph() {
        KeyboardLayout.layoutOverrideForTesting = { _ in [23: "5", 87: "5"] }
        XCTAssertEqual(KeyboardLayout.keyCode(for: Chord(command: true, key: "5")), 23)
    }

    func test_keyCodeFor_resolvesSpecialKeysWithoutTheLayout() {
        KeyboardLayout.layoutOverrideForTesting = { _ in [:] }
        XCTAssertEqual(KeyboardLayout.keyCode(for: Chord(command: true, key: "←")), 123)
        XCTAssertEqual(KeyboardLayout.keyCode(for: Chord(command: true, key: "⏎")), 36)
    }

    func test_resolve_carriesBothSpellingsOfAShiftedChord() throws {
        KeyboardLayout.layoutOverrideForTesting = { shift in shift ? [27: "_"] : [27: "-"] }
        let key = try XCTUnwrap(KeyboardLayout.resolve(Chord(command: true, shift: true, key: "-")))
        XCTAssertEqual(key.unshiftedCodepoint, UInt32(("-" as Unicode.Scalar).value))
        XCTAssertEqual(key.text, "_")
    }

    func test_resolve_hasNoSeparateTextForAnUnshiftedChord() throws {
        KeyboardLayout.layoutOverrideForTesting = { shift in shift ? [42: "|"] : [42: "\\"] }
        let key = try XCTUnwrap(KeyboardLayout.resolve(Chord(command: true, key: "\\")))
        XCTAssertEqual(key.unshiftedCodepoint, UInt32(("\\" as Unicode.Scalar).value))
        XCTAssertNil(key.text)
    }

    func test_resolve_reportsNoCodepointForKeysThatTypeNothing() throws {
        KeyboardLayout.layoutOverrideForTesting = { _ in [123: "\u{1C}", 36: "\r"] }
        for glyph in ["←", "⏎"] {
            let key = try XCTUnwrap(KeyboardLayout.resolve(Chord(command: true, key: glyph)), glyph)
            XCTAssertEqual(key.unshiftedCodepoint, 0, glyph)
            XCTAssertNil(key.text, glyph)
        }
    }

    func test_resolve_doesNotTreatAControlCharacterAsATypeableGlyph() {
        KeyboardLayout.layoutOverrideForTesting = { _ in [42: "\u{1C}"] }
        XCTAssertNil(KeyboardLayout.keyCode(for: Chord(command: true, key: "\u{1C}")))
    }

    func test_realLayout_canTypeLetters() throws {
        try XCTSkipUnless(KeyboardLayout.canType(Chord(command: true, key: "a")), "non-Latin layout")
        XCTAssertTrue(KeyboardLayout.canType(Chord(command: true, key: "z")))
    }

    func test_realLayout_reportsSomethingRatherThanNothing() throws {
        try XCTSkipUnless(KeyboardLayout.canType(Chord(command: true, key: "a")), "non-Latin layout")
        let typeableDefaults = KeymapDefaults.map.keys.filter { KeyboardLayout.canType($0) }
        XCTAssertEqual(
            typeableDefaults.count, KeymapDefaults.map.count,
            "every shipped default must be typeable on this machine's layout")
    }
}
