import AppKit
import XCTest

@testable import ZenTerm

/// `KeyboardLayout` asks the real keyboard what it can type (ZEN-121) — the one thing `Chord`'s
/// US-only fold table can't answer. Everything else stubs this seam, so these are the only tests
/// that exercise the Carbon query itself; without them the whole mechanism could be inert and every
/// other test would still pass.
final class KeyboardLayoutTests: XCTestCase {
    override func tearDown() {
        KeyboardLayout.layoutOverrideForTesting = nil
        super.tearDown()
    }

    // MARK: the stub seam

    func test_shiftedGlyphWithoutShift_isNotTypeableWhenTheLayoutNeedsShiftForIt() {
        // A US layout: `|` only ever arrives with Shift held.
        KeyboardLayout.layoutOverrideForTesting = { shift in shift ? [42: "|"] : [42: "\\"] }
        XCTAssertFalse(KeyboardLayout.canType(Chord(command: true, key: "|")))
    }

    func test_theSameGlyphIsTypeableWhenTheLayoutProducesItUnshifted() {
        // AZERTY-shaped: `_` sits on an unshifted key. Identical chord, opposite answer — which is
        // exactly why this asks the layout rather than reading the glyph.
        KeyboardLayout.layoutOverrideForTesting = { shift in shift ? [22: "6"] : [22: "_"] }
        XCTAssertTrue(KeyboardLayout.canType(Chord(command: true, key: "_")))
    }

    func test_canType_comparesThroughTheFold_soAShiftedChordMatchesItsShiftedGlyph() {
        // ⌘⇧- is typed by holding Shift and the `-` key, which arrives as "_". The check has to
        // canonicalize the layout's glyphs the same way a live event would, or it would call the
        // shipped split_horizontal default un-typeable.
        KeyboardLayout.layoutOverrideForTesting = { shift in shift ? [27: "_"] : [27: "-"] }
        XCTAssertTrue(KeyboardLayout.canType(Chord(command: true, shift: true, key: "-")))
    }

    func test_specialKeyGlyphs_bypassTheLayout() {
        // Arrows and Return are named by keyCode, never by the character tables — a layout query
        // would report them un-typeable and silently drop every arrow bind.
        KeyboardLayout.layoutOverrideForTesting = { _ in [:] }
        for glyph in ["←", "→", "↑", "↓", "⏎"] {
            XCTAssertTrue(KeyboardLayout.canType(Chord(command: true, key: glyph)), glyph)
        }
    }

    // MARK: the reverse lookup

    /// `canType` asks whether a glyph is reachable; this asks which physical key reaches it. A
    /// backend keymap matches on the keyCode, so the probe cannot ask about `cmd+\` without it.
    func test_keyCodeFor_findsTheKeyThatTypesTheGlyph() {
        KeyboardLayout.layoutOverrideForTesting = { shift in shift ? [42: "|"] : [42: "\\"] }
        XCTAssertEqual(KeyboardLayout.keyCode(for: Chord(command: true, key: "\\")), 42)
    }

    /// Through the fold, the same as `canType`: ⌘⇧- is the `-` key with Shift held, and the layout
    /// reports that key as producing "_" at that Shift state.
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

    /// The keypad carries a second `5`, and a bind written as a glyph means the main-row key.
    func test_keyCodeFor_takesTheLowestKeyWhenALayoutRepeatsAGlyph() {
        KeyboardLayout.layoutOverrideForTesting = { _ in [23: "5", 87: "5"] }
        XCTAssertEqual(KeyboardLayout.keyCode(for: Chord(command: true, key: "5")), 23)
    }

    /// Arrows and Return have no character table to search, so they resolve from `Chord`'s own
    /// keyCode map. A layout query would return nil and the probe would skip every arrow bind.
    func test_keyCodeFor_resolvesSpecialKeysWithoutTheLayout() {
        KeyboardLayout.layoutOverrideForTesting = { _ in [:] }
        XCTAssertEqual(KeyboardLayout.keyCode(for: Chord(command: true, key: "←")), 123)
        XCTAssertEqual(KeyboardLayout.keyCode(for: Chord(command: true, key: "⏎")), 36)
    }

    /// Read at the unshifted state whatever the chord's Shift is, because that is what the field
    /// means: a keymap resolving `cmd+shift+-` by glyph still wants `-`.
    func test_unshiftedCodepoint_readsTheKeysBareGlyph() {
        KeyboardLayout.layoutOverrideForTesting = { shift in shift ? [27: "_"] : [27: "-"] }
        XCTAssertEqual(KeyboardLayout.unshiftedCodepoint(forKeyCode: 27), UInt32(("-" as Unicode.Scalar).value))
        XCTAssertEqual(KeyboardLayout.unshiftedCodepoint(forKeyCode: 99), 0, "a key that types nothing")
    }

    // MARK: the real Carbon query
    //
    // Layout-dependent by nature, so these assert only what every Latin layout agrees on. A machine
    // set to a non-Latin layout could see these fail — that's the seam working, not a flake.

    func test_realLayout_canTypeLetters() throws {
        try XCTSkipUnless(KeyboardLayout.canType(Chord(command: true, key: "a")), "non-Latin layout")
        XCTAssertTrue(KeyboardLayout.canType(Chord(command: true, key: "z")))
    }

    func test_realLayout_reportsSomethingRatherThanNothing() throws {
        // The failure this guards: TIS returns nil / the data doesn't map, `producibleGlyphs` yields
        // an empty set, and EVERY keybind is judged un-typeable and silently dropped. An empty
        // layout must never quietly disable the whole keymap.
        try XCTSkipUnless(KeyboardLayout.canType(Chord(command: true, key: "a")), "non-Latin layout")
        let typeableDefaults = KeymapDefaults.map.keys.filter { KeyboardLayout.canType($0) }
        XCTAssertEqual(
            typeableDefaults.count, KeymapDefaults.map.count,
            "every shipped default must be typeable on this machine's layout")
    }
}
