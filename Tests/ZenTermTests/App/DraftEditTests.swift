import AppKit
import XCTest

@testable import ZenTerm

final class DraftEditTests: XCTestCase {
    private func key(
        _ characters: String, bare: String? = nil, flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0
    ) throws -> DraftEdit {
        DraftEdit(
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                    context: nil, characters: characters, charactersIgnoringModifiers: bare ?? characters,
                    isARepeat: false, keyCode: keyCode)))
    }

    func test_returnSends_andKeypadEnterToo_butAModifiedReturnWritesANewline() throws {
        XCTAssertEqual(try key("\r", keyCode: 36), .submit)
        XCTAssertEqual(try key("\u{3}", flags: [.numericPad, .function], keyCode: 76), .submit)
        XCTAssertEqual(try key("\r", flags: .shift, keyCode: 36), .write)
        XCTAssertEqual(try key("\r", flags: .option, keyCode: 36), .write)
    }

    func test_textWrites_withShiftOrOption() throws {
        XCTAssertEqual(try key("q"), .write)
        XCTAssertEqual(try key("Q", flags: .shift), .write)
        XCTAssertEqual(try key("å", bare: "a", flags: .option), .write)
    }

    func test_controlCAndControlUClear_butEscapeDoesNot() throws {
        XCTAssertEqual(try key("\u{3}", bare: "c", flags: .control, keyCode: 8), .clear)
        XCTAssertEqual(try key("\u{15}", bare: "u", flags: .control, keyCode: 32), .clear)
        XCTAssertEqual(try key("\u{1b}", keyCode: 53), .none)
    }

    func test_upDownAndTabWrite_sinceTheyRecallOrCompleteText() throws {
        XCTAssertEqual(try key("\u{F700}", flags: [.function, .numericPad], keyCode: 126), .write)
        XCTAssertEqual(try key("\u{F701}", flags: [.function, .numericPad], keyCode: 125), .write)
        XCTAssertEqual(try key("\t", keyCode: 48), .write)
    }

    func test_sideArrowsDeleteShiftTabAndCommandKeysLeaveTheDraft() throws {
        XCTAssertEqual(try key("\u{F702}", flags: [.function, .numericPad], keyCode: 123), .none)
        XCTAssertEqual(try key("\u{F703}", flags: [.function, .numericPad], keyCode: 124), .none)
        XCTAssertEqual(try key("\u{7f}", keyCode: 51), .none)
        XCTAssertEqual(try key("\u{19}", bare: "\t", flags: .shift, keyCode: 48), .none)
        XCTAssertEqual(try key("v", flags: .command, keyCode: 9), .none)
        XCTAssertEqual(try key("\u{1}", bare: "a", flags: .control, keyCode: 0), .none)
    }
}
