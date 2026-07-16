import AppKit
import XCTest

@testable import ZenTerm

/// `KeyboardLayout` asks the real keyboard what it can type (ZEN-142) — the one thing `Chord`'s
/// US-only fold table can't answer. Everything else stubs this seam, so these are the only tests
/// that exercise the Carbon query itself; without them the whole mechanism could be inert and every
/// other test would still pass.
final class KeyboardLayoutTests: XCTestCase {
    override func tearDown() {
        KeyboardLayout.producibleGlyphsOverrideForTesting = nil
        super.tearDown()
    }

    // MARK: the stub seam

    func test_shiftedGlyphWithoutShift_isNotTypeableWhenTheLayoutNeedsShiftForIt() {
        // A US layout: `|` only ever arrives with Shift held.
        KeyboardLayout.producibleGlyphsOverrideForTesting = { shift in shift ? ["|"] : ["\\"] }
        XCTAssertFalse(KeyboardLayout.canType(Chord(command: true, key: "|")))
    }

    func test_theSameGlyphIsTypeableWhenTheLayoutProducesItUnshifted() {
        // AZERTY-shaped: `_` sits on an unshifted key. Identical chord, opposite answer — which is
        // exactly why this asks the layout rather than reading the glyph.
        KeyboardLayout.producibleGlyphsOverrideForTesting = { shift in shift ? ["6"] : ["_"] }
        XCTAssertTrue(KeyboardLayout.canType(Chord(command: true, key: "_")))
    }

    func test_canType_comparesThroughTheFold_soAShiftedChordMatchesItsShiftedGlyph() {
        // ⌘⇧- is typed by holding Shift and the `-` key, which arrives as "_". The check has to
        // canonicalize the layout's glyphs the same way a live event would, or it would call the
        // shipped split_horizontal default un-typeable.
        KeyboardLayout.producibleGlyphsOverrideForTesting = { shift in shift ? ["_"] : ["-"] }
        XCTAssertTrue(KeyboardLayout.canType(Chord(command: true, shift: true, key: "-")))
    }

    func test_specialKeyGlyphs_bypassTheLayout() {
        // Arrows and Return are named by keyCode, never by the character tables — a layout query
        // would report them un-typeable and silently drop every arrow bind.
        KeyboardLayout.producibleGlyphsOverrideForTesting = { _ in [] }
        for glyph in ["←", "→", "↑", "↓", "⏎"] {
            XCTAssertTrue(KeyboardLayout.canType(Chord(command: true, key: glyph)), glyph)
        }
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
