import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Scroll mode's key decoder (ZEN-330). It is the whole keymap of a mode that holds the keyboard,
/// and it fails silently in both directions: a key it wrongly claims is a keystroke the shell never
/// sees, and a key it wrongly drops is a scroll that does nothing. Neither shows up on screen as
/// anything but "the terminal ignored me".
final class ScrollModeKeyTests: XCTestCase {
    private func keyDown(
        _ characters: String, unshifted: String? = nil, flags: NSEvent.ModifierFlags = [],
        keyCode: UInt16 = 0
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters,
                charactersIgnoringModifiers: unshifted ?? characters, isARepeat: false, keyCode: keyCode))
    }

    private func decode(_ event: NSEvent, afterG: Bool = false) -> ScrollModeController.Command? {
        ScrollModeController.command(for: event, afterG: afterG)
    }

    // MARK: the moves

    func test_jAndKStepTheCursorInOppositeDirections() throws {
        // A step, not a scroll: the cursor moves and the viewport only follows once it is pinned.
        XCTAssertEqual(decode(try keyDown("j")), .step(1))
        XCTAssertEqual(decode(try keyDown("k")), .step(-1))
    }

    func test_arrowsMirrorJAndK() throws {
        // Real arrow keys carry .function and .numericPad; a decoder matching the raw modifier
        // mask would miss every one of them (the ZEN-145 trap).
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        XCTAssertEqual(decode(try keyDown(down, flags: [.function, .numericPad])), .step(1))
        XCTAssertEqual(decode(try keyDown(up, flags: [.function, .numericPad])), .step(-1))
    }

    func test_controlPairsAreHalfAndFullPages() throws {
        XCTAssertEqual(decode(try keyDown("d", flags: .control)), .scroll(.pageFraction(0.5)))
        XCTAssertEqual(decode(try keyDown("u", flags: .control)), .scroll(.pageFraction(-0.5)))
        XCTAssertEqual(decode(try keyDown("f", flags: .control)), .scroll(.pageFraction(1)))
        XCTAssertEqual(decode(try keyDown("b", flags: .control)), .scroll(.pageFraction(-1)))
        XCTAssertEqual(decode(try keyDown(" ")), .scroll(.pageFraction(1)))
    }

    func test_bracesAreTheParagraphMotion() throws {
        // Vim's paragraph motion, and the same keys the diff viewer jumps changes with. Matched
        // on the typed character, so a layout that doesn't put braces on shift-bracket works.
        XCTAssertEqual(decode(try keyDown("{", unshifted: "[", flags: .shift)), .paragraph(-1))
        XCTAssertEqual(decode(try keyDown("}", unshifted: "]", flags: .shift)), .paragraph(1))
    }

    func test_aShiftBracketThatReportsNoBraceIsNotAMotion() throws {
        // `charactersIgnoringModifiers` applies Shift, so a real US shift+[ reports "{" in both
        // fields and is matched on the typed character. An event reporting "[" with Shift held is
        // one macOS never sends, and the decoder is not built to honour it: keeping a branch for
        // it meant maintaining code no keystroke could execute.
        XCTAssertNil(decode(try keyDown("[", unshifted: "[", flags: .shift)))
        XCTAssertNil(decode(try keyDown("]", unshifted: "]", flags: .shift)))
    }

    func test_bareBracketsAreNotBound() throws {
        // Vim's `[` and `]` are prefixes for two-key commands, not motions of their own.
        XCTAssertNil(decode(try keyDown("[")))
        XCTAssertNil(decode(try keyDown("]")))
    }

    // MARK: gg and G

    func test_gArmsThePrefixAndTheSecondGTopsOut() throws {
        XCTAssertEqual(decode(try keyDown("g")), .pendingTop)
        XCTAssertEqual(decode(try keyDown("g"), afterG: true), .scroll(.top))
    }

    func test_shiftGGoesToTheBottomRegardlessOfThePrefix() throws {
        let shiftG = try keyDown("G", unshifted: "g", flags: .shift)
        XCTAssertEqual(decode(shiftG), .scroll(.bottom))
        XCTAssertEqual(decode(shiftG, afterG: true), .scroll(.bottom))
    }

    func test_shiftednessComesFromTheFlagsNotTheCharacterCase() throws {
        // Caps Lock uppercases too. Read case instead of flags and a single `g` with Caps Lock on
        // jumps to the bottom of the buffer, and `j` stops scrolling entirely.
        XCTAssertEqual(decode(try keyDown("G", unshifted: "G")), .pendingTop)
        XCTAssertEqual(decode(try keyDown("J", unshifted: "J")), .step(1))
    }

    // MARK: the column (ZEN-331)

    func test_hAndLMoveOneCellSideways() throws {
        XCTAssertEqual(decode(try keyDown("h")), .column(-1))
        XCTAssertEqual(decode(try keyDown("l")), .column(1))
    }

    func test_sideArrowsMirrorHAndL() throws {
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        // Real arrow events, with the flags AppKit actually puts on one. A synthesized bare arrow
        // is a keystroke macOS never sends.
        XCTAssertEqual(decode(try keyDown(left, flags: [.function, .numericPad])), .column(-1))
        XCTAssertEqual(decode(try keyDown(right, flags: [.function, .numericPad])), .column(1))
    }

    func test_wbeAreTheWordMotions() throws {
        XCTAssertEqual(decode(try keyDown("w")), .word(.next))
        XCTAssertEqual(decode(try keyDown("b")), .word(.back))
        XCTAssertEqual(decode(try keyDown("e")), .word(.end))
    }

    func test_controlBStillPagesUpRatherThanMovingAWord() throws {
        // `b` is a word motion bare and a page up with Control. The Control branch runs first, so
        // the pair cannot collide, and this is the assertion that keeps it that way.
        XCTAssertEqual(decode(try keyDown("b", flags: .control)), .scroll(.pageFraction(-1)))
    }

    func test_zeroAndDollarAreTheEndsOfTheRow() throws {
        XCTAssertEqual(decode(try keyDown("0")), .lineStart)
        // `$` is shift+4, so `charactersIgnoringModifiers` reports "4" and only the typed character
        // names it. A layout that puts `$` elsewhere reports it here too.
        XCTAssertEqual(decode(try keyDown("$", unshifted: "4", flags: .shift)), .lineEnd)
    }

    // MARK: selection (ZEN-331)

    func test_vAndShiftVOpenTheTwoKindsOfSelection() throws {
        XCTAssertEqual(decode(try keyDown("v")), .visual(.character))
        XCTAssertEqual(decode(try keyDown("V", unshifted: "v", flags: .shift)), .visual(.line))
    }

    func test_yYanks() throws {
        XCTAssertEqual(decode(try keyDown("y")), .yank)
    }

    // MARK: leaving

    func test_escapeCancelsAndQAndILeaveTheMode() throws {
        // Esc is `.cancel`, not `.exit`: with a selection up it gives the selection back, and only
        // an Esc with nothing to give back closes the mode. `q` and `i` leave either way.
        XCTAssertEqual(decode(try keyDown("\u{1b}", keyCode: 53)), .cancel)
        XCTAssertEqual(decode(try keyDown("q")), .exit)
        XCTAssertEqual(decode(try keyDown("i")), .exit)
    }

    // MARK: what the mode must not claim

    func test_commandAndOptionChordsFallThrough_soReservedChordsStillResolve() throws {
        // These reach the decoder only if the keymap missed them, and claiming one here would
        // shadow whatever the user binds to it.
        XCTAssertNil(decode(try keyDown("j", flags: .command)))
        XCTAssertNil(decode(try keyDown("d", flags: [.command, .control])))
        XCTAssertNil(decode(try keyDown("j", flags: .option)))
    }

    func test_unmappedKeysDecodeToNothing() throws {
        XCTAssertNil(decode(try keyDown("x")))
        XCTAssertNil(decode(try keyDown("5")))
    }
}

/// The header text scroll mode puts on the pane, which is the only thing telling a reader where in
/// the buffer they are. Tested because "at bottom" vs a count is a distinction the eye can't
/// recover once it is wrong.
final class ScrollModeHeaderTests: XCTestCase {
    func test_readsScrollBeforeTheFirstReport() {
        XCTAssertEqual(ScrollModeController.headerTitle(nil), "Scroll")
    }

    func test_saysAtBottomWhenNothingIsBelowTheViewport() {
        let resting = TerminalScrollPosition(total: 500, offset: 460, viewport: 40)
        XCTAssertEqual(resting.linesBelow, 0)
        XCTAssertEqual(ScrollModeController.headerTitle(resting), "Scroll: at bottom")
    }

    func test_countsTheLinesBelowTheViewportWithASeparator() {
        // The count is grouped for the reader's locale, so the expectation is built the same way
        // rather than hardcoding US separators. Asserting "3,760" reddens bin/check on a machine
        // set to German ("3.760") or Swedish ("3 760") for a reason unrelated to the change.
        let scrolledUp = TerminalScrollPosition(total: 5000, offset: 1200, viewport: 40)
        XCTAssertEqual(scrolledUp.linesBelow, 3760)
        let grouped = ScrollModeController.groupedCount(3760)
        XCTAssertTrue(grouped.contains("760"), "expected a grouped count, got \(grouped)")
        XCTAssertEqual(ScrollModeController.headerTitle(scrolledUp), "Scroll: \(grouped) below")
    }

    func test_aLineSelectionCountsItsRowsAndAgreesWithItself() {
        XCTAssertEqual(ScrollModeController.visualTitle(kind: .line, rows: 1), "Visual: 1 line")
        XCTAssertEqual(ScrollModeController.visualTitle(kind: .line, rows: 4), "Visual: 4 lines")
    }

    func test_aCharacterSelectionGetsNoCount() {
        // The number that would mean anything is characters, and it moves on every `l`. A row count
        // beside a charwise selection reads as the thing the yank will take, and is not.
        XCTAssertEqual(ScrollModeController.visualTitle(kind: .character, rows: 3), "Visual")
    }
}
