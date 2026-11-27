import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class SearchKeyTests: XCTestCase {
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

    private func decode(_ event: NSEvent) -> SearchController.Key? {
        SearchController.key(for: event)
    }

    func test_nStepsForwardAndShiftNBack() throws {
        XCTAssertEqual(decode(try keyDown("n")), .step(.next))
        XCTAssertEqual(decode(try keyDown("N", unshifted: "n", flags: .shift)), .step(.previous))
    }

    func test_returnMirrorsNAndKeypadEnterCountsToo() throws {
        XCTAssertEqual(decode(try keyDown("\r", keyCode: 36)), .step(.next))
        XCTAssertEqual(decode(try keyDown("\r", flags: .shift, keyCode: 36)), .step(.previous))
        XCTAssertEqual(decode(try keyDown("\r", keyCode: 76)), .step(.next))
    }

    func test_escapeEndsTheSearch() throws {
        XCTAssertEqual(decode(try keyDown("\u{1b}", keyCode: 53)), .end)
    }

    func test_shiftednessComesFromTheFlagsNotTheCharacterCase() throws {
        XCTAssertEqual(decode(try keyDown("N", unshifted: "N")), .step(.next))
    }

    func test_commandAndOptionChordsFallThrough() throws {
        XCTAssertNil(decode(try keyDown("n", flags: .command)))
        XCTAssertNil(decode(try keyDown("n", flags: [.command, .shift])))
        XCTAssertNil(decode(try keyDown("w", flags: .command)))
        XCTAssertNil(decode(try keyDown("n", flags: .option)))
    }

    func test_unmappedKeysDecodeToNothing() throws {
        XCTAssertNil(decode(try keyDown("j")))
        XCTAssertNil(decode(try keyDown("x")))
        XCTAssertNil(decode(try keyDown("n", flags: .control)))
    }
}
