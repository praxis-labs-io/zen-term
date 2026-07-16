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

    func test_widthHeight_clampedToSaneRange() {
        let float = ToolFloatParser.parse("id:x command:c key:cmd+shift+j width:5 height:0")
        XCTAssertEqual(float?.widthFraction, 1.0)  // 5 → clamped to 1.0
        XCTAssertEqual(float?.heightFraction, 0.2)  // 0 → clamped to 0.2 (never an invalid multiplier)
    }

    func test_git_caseInsensitive() {
        XCTAssertEqual(ToolFloatParser.parse("id:x command:c key:cmd+shift+j git:True")?.requiresGitRepo, true)
        XCTAssertEqual(ToolFloatParser.parse("id:x command:c key:cmd+shift+j git:TRUE")?.requiresGitRepo, true)
    }

    func test_missingRequiredFields_returnNil() {
        XCTAssertNil(ToolFloatParser.parse("command:foo key:cmd+shift+j"))  // no id
        XCTAssertNil(ToolFloatParser.parse("id:x key:cmd+shift+j"))  // no command
        XCTAssertNil(ToolFloatParser.parse("id:x command:foo"))  // no key
        XCTAssertNil(ToolFloatParser.parse("id:x command:foo key:nope+"))  // unparseable key
    }

    func test_persist_defaultsToEphemeral() {
        let float = ToolFloatParser.parse("id:x command:c key:cmd+shift+j")
        XCTAssertEqual(float?.persist, .ephemeral)
    }

    func test_persist_parsesEveryToken() {
        XCTAssertEqual(ToolFloatParser.parse("id:x command:c key:cmd+shift+j persist:none")?.persist, .ephemeral)
        XCTAssertEqual(ToolFloatParser.parse("id:x command:c key:cmd+shift+j persist:dir")?.persist, .directory)
        XCTAssertEqual(ToolFloatParser.parse("id:x command:c key:cmd+shift+j persist:tab")?.persist, .tab)
    }

    func test_persist_caseInsensitive() {
        XCTAssertEqual(ToolFloatParser.parse("id:x command:c key:cmd+shift+j persist:DIR")?.persist, .directory)
    }

    /// An unknown value must not drop the whole float — the float still works, just ephemerally.
    func test_persist_unknownValue_fallsBackToEphemeral() {
        let float = ToolFloatParser.parse("id:x command:c key:cmd+shift+j persist:banana")
        XCTAssertEqual(float?.persist, .ephemeral)
        XCTAssertEqual(float?.id, "x")
    }

    /// `window` is ZEN-141. Until then it must degrade, not silently look supported.
    func test_persist_window_isNotYetSupported() {
        XCTAssertEqual(ToolFloatParser.parse("id:x command:c key:cmd+shift+j persist:window")?.persist, .ephemeral)
    }

    func test_dir_defaultsToNil() {
        XCTAssertNil(ToolFloatParser.parse("id:x command:c key:cmd+shift+j")?.dir)
    }

    func test_dir_expandsTilde() {
        let float = ToolFloatParser.parse("id:x command:c key:cmd+shift+j dir:~/notes")
        XCTAssertEqual(float?.dir?.path, NSString(string: "~/notes").expandingTildeInPath)
    }

    func test_dir_quotedPathWithSpaces() {
        let float = ToolFloatParser.parse("id:x command:c key:cmd+shift+j dir:\"/tmp/my notes\"")
        XCTAssertEqual(float?.dir?.path, "/tmp/my notes")
    }

    /// A pinned dir has a fixed identity, so `persist:dir` can never re-anchor — it degenerates into
    /// exactly `persist:tab`. Warn and keep the float rather than guessing.
    func test_dirWithPersistDir_isDegenerate_butKeepsTheFloat() {
        let float = ToolFloatParser.parse("id:x command:c key:cmd+shift+j dir:/tmp persist:dir")
        XCTAssertEqual(float?.persist, .directory)
        XCTAssertEqual(float?.dir?.path, "/tmp")
    }
}
