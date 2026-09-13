import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

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

    private func decode(
        _ event: NSEvent, afterG: Bool = false, afterY: Bool = false,
        awaitingFind: ScrollKeymap.Find.Target? = nil, count: Int? = nil, hasSelection: Bool = false
    ) -> ScrollKeymap.Command? {
        let pending = ScrollKeymap.Pending(
            afterG: afterG, afterY: afterY, awaitingFind: awaitingFind, count: count)
        guard
            case .run(let command) =
                ScrollKeymap.key(for: event, pending: pending, hasSelection: hasSelection)
        else { return nil }
        return command
    }

    private func count(_ event: NSEvent, count: Int? = nil) -> Int? {
        guard
            case .count(let digit) =
                ScrollKeymap.key(for: event, pending: .init(count: count))
        else { return nil }
        return digit
    }

    func test_jAndKStepTheCursorInOppositeDirections() throws {
        XCTAssertEqual(decode(try keyDown("j")), .step(1))
        XCTAssertEqual(decode(try keyDown("k")), .step(-1))
    }

    func test_arrowsMirrorJAndK() throws {
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
        XCTAssertEqual(decode(try keyDown("{", unshifted: "[", flags: .shift)), .paragraph(-1, times: 1))
        XCTAssertEqual(decode(try keyDown("}", unshifted: "]", flags: .shift)), .paragraph(1, times: 1))
    }

    func test_aShiftBracketThatReportsNoBraceIsNotAMotion() throws {
        XCTAssertNil(decode(try keyDown("[", unshifted: "[", flags: .shift)))
        XCTAssertNil(decode(try keyDown("]", unshifted: "]", flags: .shift)))
    }

    func test_bareBracketsAreNotBound() throws {
        XCTAssertNil(decode(try keyDown("[")))
        XCTAssertNil(decode(try keyDown("]")))
    }

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
        XCTAssertEqual(decode(try keyDown("G", unshifted: "G")), .pendingTop)
        XCTAssertEqual(decode(try keyDown("J", unshifted: "J")), .step(1))
    }

    func test_hAndLMoveOneCellSideways() throws {
        XCTAssertEqual(decode(try keyDown("h")), .column(-1))
        XCTAssertEqual(decode(try keyDown("l")), .column(1))
    }

    func test_sideArrowsMirrorHAndL() throws {
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        XCTAssertEqual(decode(try keyDown(left, flags: [.function, .numericPad])), .column(-1))
        XCTAssertEqual(decode(try keyDown(right, flags: [.function, .numericPad])), .column(1))
    }

    func test_wbeAreTheWordMotions() throws {
        XCTAssertEqual(decode(try keyDown("w")), .word(.next, wide: false, times: 1))
        XCTAssertEqual(decode(try keyDown("b")), .word(.back, wide: false, times: 1))
        XCTAssertEqual(decode(try keyDown("e")), .word(.end, wide: false, times: 1))
    }

    func test_shiftedWordMotionsAreWhitespaceDelimited() throws {
        XCTAssertEqual(
            decode(try keyDown("W", unshifted: "w", flags: .shift)),
            .word(.next, wide: true, times: 1))
        XCTAssertEqual(
            decode(try keyDown("B", unshifted: "b", flags: .shift)),
            .word(.back, wide: true, times: 1))
        XCTAssertEqual(
            decode(try keyDown("E", unshifted: "e", flags: .shift)),
            .word(.end, wide: true, times: 1))
    }

    func test_hmlNameARowByWhereItSitsOnScreen() throws {
        XCTAssertEqual(
            decode(try keyDown("H", unshifted: "h", flags: .shift)),
            .viewportRow(.top, offset: 0))
        XCTAssertEqual(
            decode(try keyDown("M", unshifted: "m", flags: .shift)),
            .viewportRow(.middle, offset: 0))
        XCTAssertEqual(
            decode(try keyDown("L", unshifted: "l", flags: .shift)),
            .viewportRow(.bottom, offset: 0))
        XCTAssertEqual(
            decode(try keyDown("H", unshifted: "h", flags: .shift), count: 3),
            .viewportRow(.top, offset: 2), "`3H` is the third row down, so the count is an offset")
    }

    func test_caretAndStarAreTypedCharacters() throws {
        XCTAssertEqual(decode(try keyDown("^", unshifted: "6", flags: .shift)), .firstNonBlank)
        XCTAssertEqual(
            decode(try keyDown("*", unshifted: "8", flags: .shift)), .searchWordUnderCursor)
    }

    func test_controlBStillPagesUpRatherThanMovingAWord() throws {
        XCTAssertEqual(decode(try keyDown("b", flags: .control)), .scroll(.pageFraction(-1)))
    }

    func test_zeroAndDollarAreTheEndsOfTheRow() throws {
        XCTAssertEqual(decode(try keyDown("0")), .lineStart)
        XCTAssertEqual(decode(try keyDown("$", unshifted: "4", flags: .shift)), .lineEnd)
    }

    func test_vAndShiftVOpenTheTwoKindsOfSelection() throws {
        XCTAssertEqual(decode(try keyDown("v")), .visual(.character))
        XCTAssertEqual(decode(try keyDown("V", unshifted: "v", flags: .shift)), .visual(.line))
    }

    func test_yTakesASelectionAndOtherwiseWaitsForASecondY() throws {
        XCTAssertEqual(decode(try keyDown("y"), hasSelection: true), .yank)
        XCTAssertEqual(decode(try keyDown("y")), .pendingYank)
        XCTAssertEqual(decode(try keyDown("y"), afterY: true), .yankRow(times: 1))
        XCTAssertEqual(decode(try keyDown("y"), afterY: true, count: 3), .yankRow(times: 3))
    }

    func test_ftArmAFindAndTheNextKeyIsItsCharacter() throws {
        XCTAssertEqual(
            decode(try keyDown("f")), .pendingFind(.init(direction: .forward, till: false)))
        XCTAssertEqual(
            decode(try keyDown("F", unshifted: "f", flags: .shift)),
            .pendingFind(.init(direction: .backward, till: false)))
        XCTAssertEqual(
            decode(try keyDown("t")), .pendingFind(.init(direction: .forward, till: true)))
        XCTAssertEqual(
            decode(try keyDown("T", unshifted: "t", flags: .shift)),
            .pendingFind(.init(direction: .backward, till: true)))
    }

    func test_theCharacterAfterAFindIsTakenWholeSale() throws {
        let forward = ScrollKeymap.Find.Target(direction: .forward, till: false)
        XCTAssertEqual(
            decode(try keyDown("j"), awaitingFind: forward),
            .find(.init(direction: .forward, till: false, character: "j"), times: 1))
        XCTAssertEqual(
            decode(try keyDown("0"), awaitingFind: forward),
            .find(.init(direction: .forward, till: false, character: "0"), times: 1))
    }

    func test_escapeWaitingOnAFindCancelsTheFindRatherThanTheMode() throws {
        let forward = ScrollKeymap.Find.Target(direction: .forward, till: false)
        XCTAssertEqual(decode(try keyDown("\u{1b}", keyCode: 53)), .cancel)
        XCTAssertNil(
            decode(try keyDown("\u{1b}", keyCode: 53), awaitingFind: forward),
            "unmapped, so the caller drops what was armed and does nothing else")
    }

    func test_semicolonAndCommaRepeatTheLastFind() throws {
        XCTAssertEqual(decode(try keyDown(";")), .repeatFind(reversed: false, times: 1))
        XCTAssertEqual(decode(try keyDown(",")), .repeatFind(reversed: true, times: 1))
    }

    func test_escapeCancelsAndQAndILeaveTheMode() throws {
        XCTAssertEqual(decode(try keyDown("\u{1b}", keyCode: 53)), .cancel)
        XCTAssertEqual(decode(try keyDown("q")), .exit)
        XCTAssertEqual(decode(try keyDown("i")), .exit)
    }

    func test_commandAndOptionChordsFallThrough_soReservedChordsStillResolve() throws {
        XCTAssertNil(decode(try keyDown("j", flags: .command)))
        XCTAssertNil(decode(try keyDown("d", flags: [.command, .control])))
        XCTAssertNil(decode(try keyDown("j", flags: .option)))
    }

    func test_unmappedKeysDecodeToNothing() throws {
        XCTAssertNil(decode(try keyDown("x")))
    }

    func test_digitsFoldIntoTheCountRatherThanRunning() throws {
        XCTAssertEqual(count(try keyDown("5")), 5)
        XCTAssertNil(decode(try keyDown("5")), "a digit is not a move")
        XCTAssertEqual(count(try keyDown("2"), count: 1), 2, "the caller folds it into 12")
    }

    func test_aCountMultipliesTheMotionItPrefixes() throws {
        XCTAssertEqual(decode(try keyDown("j"), count: 12), .step(12))
        XCTAssertEqual(decode(try keyDown("k"), count: 3), .step(-3))
        XCTAssertEqual(decode(try keyDown("l"), count: 4), .column(4))
        XCTAssertEqual(decode(try keyDown("w"), count: 3), .word(.next, wide: false, times: 3))
        XCTAssertEqual(
            decode(try keyDown("}", unshifted: "]", flags: .shift), count: 2),
            .paragraph(1, times: 2), "the count repeats the motion; it never becomes the stride")
    }

    func test_aCountScalesThePageRatherThanRepeatingIt() throws {
        XCTAssertEqual(
            decode(try keyDown("d", flags: .control), count: 3), .scroll(.pageFraction(1.5)))
    }

    func test_zeroIsTheLineStartUntilACountIsBeingTyped() throws {
        XCTAssertEqual(decode(try keyDown("0")), .lineStart)
        XCTAssertEqual(count(try keyDown("0"), count: 1), 0, "the second key of `10`")
        XCTAssertNil(decode(try keyDown("0"), count: 1), "and it runs nothing")
    }
}

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
        let grouped = ScrollModeController.groupedCount(3760)
        XCTAssertTrue(grouped.contains("760"), "expected a grouped count, got \(grouped)")
        XCTAssertEqual(ScrollModeController.headerTitle(scrolledUp), "Scroll: \(grouped) below")
    }

    func test_aLineSelectionCountsItsRowsAndAgreesWithItself() {
        XCTAssertEqual(ScrollModeController.visualTitle(kind: .line, rows: 1), "Visual: 1 line")
        XCTAssertEqual(ScrollModeController.visualTitle(kind: .line, rows: 4), "Visual: 4 lines")
    }

    func test_aCharacterSelectionGetsNoCount() {
        XCTAssertEqual(ScrollModeController.visualTitle(kind: .character, rows: 3), "Visual")
    }
}
