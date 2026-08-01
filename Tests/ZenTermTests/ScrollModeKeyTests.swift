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

    func test_jAndKMoveOneLineInOppositeDirections() throws {
        XCTAssertEqual(decode(try keyDown("j")), .scroll(.lines(1)))
        XCTAssertEqual(decode(try keyDown("k")), .scroll(.lines(-1)))
    }

    func test_arrowsMirrorJAndK() throws {
        // Real arrow keys carry .function and .numericPad; a decoder matching the raw modifier
        // mask would miss every one of them (the ZEN-145 trap).
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        XCTAssertEqual(decode(try keyDown(down, flags: [.function, .numericPad])), .scroll(.lines(1)))
        XCTAssertEqual(decode(try keyDown(up, flags: [.function, .numericPad])), .scroll(.lines(-1)))
    }

    func test_controlPairsAreHalfAndFullPages() throws {
        XCTAssertEqual(decode(try keyDown("d", flags: .control)), .scroll(.pageFraction(0.5)))
        XCTAssertEqual(decode(try keyDown("u", flags: .control)), .scroll(.pageFraction(-0.5)))
        XCTAssertEqual(decode(try keyDown("f", flags: .control)), .scroll(.pageFraction(1)))
        XCTAssertEqual(decode(try keyDown("b", flags: .control)), .scroll(.pageFraction(-1)))
        XCTAssertEqual(decode(try keyDown(" ")), .scroll(.pageFraction(1)))
    }

    func test_bracketsJumpBetweenPrompts() throws {
        XCTAssertEqual(decode(try keyDown("[")), .scroll(.prompt(-1)))
        XCTAssertEqual(decode(try keyDown("]")), .scroll(.prompt(1)))
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
        XCTAssertEqual(decode(try keyDown("J", unshifted: "J")), .scroll(.lines(1)))
    }

    // MARK: leaving

    func test_escapeAndQAndILeaveTheMode() throws {
        XCTAssertEqual(decode(try keyDown("\u{1b}", keyCode: 53)), .exit)
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
        let scrolledUp = TerminalScrollPosition(total: 5000, offset: 1200, viewport: 40)
        XCTAssertEqual(scrolledUp.linesBelow, 3760)
        XCTAssertEqual(ScrollModeController.headerTitle(scrolledUp), "Scroll: 3,760 below")
    }
}
