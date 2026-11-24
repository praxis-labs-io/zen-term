import AppKit
import XCTest

@testable import ZenTerm

final class DraftEditTests: XCTestCase {
    private func key(
        _ characters: String, bare: String? = nil, flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0,
        composing: Bool = false
    ) throws -> DraftEdit {
        DraftEdit(
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                    context: nil, characters: characters, charactersIgnoringModifiers: bare ?? characters,
                    isARepeat: false, keyCode: keyCode)),
            composing: composing)
    }

    func test_returnSends_andKeypadEnterToo_butAModifiedReturnWritesANewline() throws {
        XCTAssertEqual(try key("\r", keyCode: 36), .submit)
        XCTAssertEqual(try key("\u{3}", flags: [.numericPad, .function], keyCode: 76), .submit)
        XCTAssertEqual(try key("\r", flags: .shift, keyCode: 36), .add("\n"))
        XCTAssertEqual(try key("\r", flags: .option, keyCode: 36), .add("\n"))
    }

    func test_textAddsWhatItTypes_withShiftOrOption() throws {
        XCTAssertEqual(try key("q"), .add("q"))
        XCTAssertEqual(try key("Q", flags: .shift), .add("Q"))
        XCTAssertEqual(try key("å", bare: "a", flags: .option), .add("å"))
    }

    func test_backspaceRemovesOne_andAWordOrLineDeleteRemovesAnUnknownAmount() throws {
        XCTAssertEqual(try key("\u{7f}", keyCode: 51), .removeOne)
        XCTAssertEqual(try key("\u{7f}", flags: .option, keyCode: 51), .removeUnknown)
        XCTAssertEqual(try key("\u{7f}", flags: .command, keyCode: 51), .removeUnknown)
        XCTAssertEqual(try key("\u{F728}", flags: [.function], keyCode: 117), .removeUnknown)
        XCTAssertEqual(try key("\u{17}", bare: "w", flags: .control, keyCode: 13), .removeUnknown)
        XCTAssertEqual(try key("\u{b}", bare: "k", flags: .control, keyCode: 40), .removeUnknown)
        XCTAssertEqual(try key("\u{8}", bare: "h", flags: .control, keyCode: 4), .removeUnknown)
    }

    func test_controlCAndControlUClear_butEscapeDoesNot() throws {
        XCTAssertEqual(try key("\u{3}", bare: "c", flags: .control, keyCode: 8), .clear)
        XCTAssertEqual(try key("\u{15}", bare: "u", flags: .control, keyCode: 32), .clear)
        XCTAssertEqual(try key("\u{1b}", keyCode: 53), .none)
    }

    func test_upDownAndTabAddUnknownText_sinceTheyRecallOrCompleteIt() throws {
        XCTAssertEqual(try key("\u{F700}", flags: [.function, .numericPad], keyCode: 126), .addUnknown)
        XCTAssertEqual(try key("\u{F701}", flags: [.function, .numericPad], keyCode: 125), .addUnknown)
        XCTAssertEqual(try key("\t", keyCode: 48), .addUnknown)
    }

    func test_sideArrowsShiftTabAndCommandKeysLeaveTheDraft() throws {
        XCTAssertEqual(try key("\u{F702}", flags: [.function, .numericPad], keyCode: 123), .none)
        XCTAssertEqual(try key("\u{F703}", flags: [.function, .numericPad], keyCode: 124), .none)
        XCTAssertEqual(try key("\u{19}", bare: "\t", flags: .shift, keyCode: 48), .none)
        XCTAssertEqual(try key("v", flags: .command, keyCode: 9), .none)
        XCTAssertEqual(try key("\u{1}", bare: "a", flags: .control, keyCode: 0), .none)
    }

    func test_whileAnInputMethodComposesAKeyAddsUnknownText_butEscapeAndClearingKeysKeepTheirMeaning() throws {
        XCTAssertEqual(try key("\r", keyCode: 36, composing: true), .addUnknown)
        XCTAssertEqual(try key("n", keyCode: 45, composing: true), .addUnknown)
        XCTAssertEqual(try key("\u{7f}", keyCode: 51, composing: true), .addUnknown)
        XCTAssertEqual(try key("\u{1b}", keyCode: 53, composing: true), .none)
        XCTAssertEqual(try key("\u{15}", bare: "u", flags: .control, keyCode: 32, composing: true), .clear)
    }
}
