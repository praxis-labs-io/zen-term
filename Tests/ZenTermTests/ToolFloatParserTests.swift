import XCTest

@testable import ZenTerm

final class ToolFloatParserTests: XCTestCase {
    func test_minimalLine_usesDefaults() {
        let float = ToolFloatParser.parse("id:x command:foo key:cmd+shift+j")
        XCTAssertEqual(float?.id, "x")
        XCTAssertEqual(float?.command, "foo")
        XCTAssertEqual(float?.title, "Open x")
        XCTAssertEqual(float?.icon, "square.on.square")
        XCTAssertEqual(float?.widthFraction, 0.85)
        XCTAssertEqual(float?.heightFraction, 0.85)
        XCTAssertEqual(float?.requiresGitRepo, false)
        XCTAssertEqual(float?.shortcut, "⌘⇧J")
        XCTAssertEqual(float?.toggle, Chord(command: true, shift: true, key: "j"))
    }

    func test_gitTrue() {
        let float = ToolFloatParser.parse("id:g command:lazygit key:cmd+shift+g git:true")
        XCTAssertEqual(float?.requiresGitRepo, true)
    }

    func test_extendedFields() {
        let float = ToolFloatParser.parse(
            "id:t command:top key:cmd+shift+t title:Monitor icon:gauge width:0.5 height:0.6")
        XCTAssertEqual(float?.title, "Monitor")
        XCTAssertEqual(float?.icon, "gauge")
        XCTAssertEqual(float?.widthFraction, 0.5)
        XCTAssertEqual(float?.heightFraction, 0.6)
    }

    func test_quotedMultiWordCommand() {
        let float = ToolFloatParser.parse("id:dev command:\"npm run dev\" key:cmd+shift+d")
        XCTAssertEqual(float?.command, "npm run dev")
    }

    func test_missingRequiredFields_returnNil() {
        XCTAssertNil(ToolFloatParser.parse("command:foo key:cmd+shift+j"))  // no id
        XCTAssertNil(ToolFloatParser.parse("id:x key:cmd+shift+j"))  // no command
        XCTAssertNil(ToolFloatParser.parse("id:x command:foo"))  // no key
        XCTAssertNil(ToolFloatParser.parse("id:x command:foo key:nope+"))  // unparseable key
    }
}
