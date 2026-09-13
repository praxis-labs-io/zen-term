import XCTest

@testable import ZenTerm

final class ToolFloatParserTests: XCTestCase {
    func test_minimalLine_usesDefaults() {
        let float = ToolFloatParser.parse("title:x command:foo key:cmd+shift+j")
        XCTAssertEqual(float?.id, "x")
        XCTAssertEqual(float?.command, "foo")
        XCTAssertEqual(float?.title, "x")
        XCTAssertEqual(float?.icon, ToolFloatParser.defaultIcon)
        XCTAssertEqual(float?.widthFraction, 0.85)
        XCTAssertEqual(float?.heightFraction, 0.85)
        XCTAssertEqual(float?.requiresGitRepo, false)
        XCTAssertEqual(float?.toggle, Chord(command: true, shift: true, key: "j"))
    }

    func test_gitTrue() {
        let float = ToolFloatParser.parse("title:g command:lazygit key:cmd+shift+g git:true")
        XCTAssertEqual(float?.requiresGitRepo, true)
    }

    func test_extendedFields() {
        let float = ToolFloatParser.parse(
            "command:top key:cmd+shift+t title:Monitor icon:gauge width:0.5 height:0.6")
        XCTAssertEqual(float?.title, "Monitor")
        XCTAssertEqual(float?.icon, "gauge")
        XCTAssertEqual(float?.widthFraction, 0.5)
        XCTAssertEqual(float?.heightFraction, 0.6)
    }

    func test_quotedMultiWordCommand() {
        let float = ToolFloatParser.parse("title:dev command:\"npm run dev\" key:cmd+shift+d")
        XCTAssertEqual(float?.command, "npm run dev")
    }

    func test_widthHeight_clampedToSaneRange() {
        let float = ToolFloatParser.parse("title:x command:c key:cmd+shift+j width:5 height:0")
        XCTAssertEqual(float?.widthFraction, 1.0)
        XCTAssertEqual(float?.heightFraction, 0.2)
    }

    func test_git_caseInsensitive() {
        XCTAssertEqual(ToolFloatParser.parse("title:x command:c key:cmd+shift+j git:True")?.requiresGitRepo, true)
        XCTAssertEqual(ToolFloatParser.parse("title:x command:c key:cmd+shift+j git:TRUE")?.requiresGitRepo, true)
    }

    func test_missingRequiredFields_returnNil() {
        XCTAssertNil(ToolFloatParser.parse("command:foo key:cmd+shift+j"))
        XCTAssertNil(ToolFloatParser.parse("title:x key:cmd+shift+j"))
        XCTAssertNil(ToolFloatParser.parse("title:x command:foo"))
        XCTAssertNil(ToolFloatParser.parse("title:x command:foo key:nope+"))
    }

    func test_parseLine_missingTitle_reportsMissingTitle() {
        let result = ToolFloatParser.parseLine("command:foo key:cmd+shift+j")
        XCTAssertNil(result.float)
        XCTAssertEqual(
            result.diagnostics,
            [ConfigDiagnostic(scope: .toolFloat(label: "a float line"), problem: .floatMissingField("title:"))])
    }

    func test_parseLine_missingCommand_reportsMissingCommandLabelledByTitle() {
        let result = ToolFloatParser.parseLine("title:Notes key:cmd+shift+n")
        XCTAssertNil(result.float)
        XCTAssertEqual(
            result.diagnostics,
            [ConfigDiagnostic(scope: .toolFloat(label: "Notes"), problem: .floatMissingField("command:"))])
    }

    func test_parseLine_missingKey_reportsMissingKey() {
        let result = ToolFloatParser.parseLine("title:Notes command:foo")
        XCTAssertNil(result.float)
        XCTAssertEqual(
            result.diagnostics,
            [ConfigDiagnostic(scope: .toolFloat(label: "Notes"), problem: .floatMissingField("key:"))])
    }

    func test_parseLine_emptyKey_reportsMissingNotUnusable() {
        let result = ToolFloatParser.parseLine("title:Notes command:foo key:")
        XCTAssertNil(result.float)
        XCTAssertEqual(
            result.diagnostics,
            [ConfigDiagnostic(scope: .toolFloat(label: "Notes"), problem: .floatMissingField("key:"))])
    }

    func test_parseLine_unparseableKey_reportsUnusableKey() {
        let result = ToolFloatParser.parseLine("title:Notes command:foo key:nope+")
        XCTAssertNil(result.float)
        XCTAssertEqual(
            result.diagnostics,
            [ConfigDiagnostic(scope: .toolFloat(label: "Notes"), problem: .floatUnusableKey("nope+"))])
    }

    func test_parseLine_validFloat_hasNoDiagnostics() {
        let result = ToolFloatParser.parseLine("title:x command:c key:cmd+shift+j")
        XCTAssertNotNil(result.float)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func test_parseLine_unparseableWidth_keepsFloatAndReportsInvalid() {
        let result = ToolFloatParser.parseLine("title:Notes command:c key:cmd+shift+n width:big")
        XCTAssertEqual(result.float?.widthFraction, ToolFloatParser.defaultFraction)
        XCTAssertEqual(
            result.diagnostics,
            [
                ConfigDiagnostic(
                    scope: .toolFloatField(id: "notes", label: "Notes"),
                    problem: .floatFieldInvalid(field: "width:", got: "big", using: "0.85"))
            ])
    }

    func test_parseLine_outOfRangeHeight_keepsFloatAndReportsClamp() {
        let result = ToolFloatParser.parseLine("title:Notes command:c key:cmd+shift+n height:5")
        XCTAssertEqual(result.float?.heightFraction, 1.0)
        XCTAssertEqual(
            result.diagnostics,
            [
                ConfigDiagnostic(
                    scope: .toolFloatField(id: "notes", label: "Notes"),
                    problem: .floatFieldClamped(field: "height:", got: "5", to: "1"))
            ])
    }

    func test_parseLine_nonIntegerOrder_keepsFloatAndReportsInvalid() {
        let result = ToolFloatParser.parseLine(
            "title:Notes command:c key:cmd+shift+n order:nope", fallbackOrder: 3)
        XCTAssertEqual(result.float?.order, 3)
        XCTAssertEqual(
            result.diagnostics,
            [
                ConfigDiagnostic(
                    scope: .toolFloatField(id: "notes", label: "Notes"),
                    problem: .floatFieldInvalid(field: "order:", got: "nope", using: "file order"))
            ])
    }

    func test_parseLine_unknownPersist_keepsFloatAndReportsInvalid() {
        let result = ToolFloatParser.parseLine("title:Notes command:c key:cmd+shift+n persist:banana")
        XCTAssertEqual(result.float?.persist, .ephemeral)
        XCTAssertEqual(
            result.diagnostics,
            [
                ConfigDiagnostic(
                    scope: .toolFloatField(id: "notes", label: "Notes"),
                    problem: .floatFieldInvalid(field: "persist:", got: "banana", using: "none"))
            ])
    }

    func test_parseLine_omittedOptionalFields_areSilent() {
        let result = ToolFloatParser.parseLine("title:Notes command:c key:cmd+shift+n")
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func test_id_isSlugOfTitle() {
        XCTAssertEqual(slugOf("Open GitDash"), "open-gitdash")
        XCTAssertEqual(slugOf("BTop"), "btop")
        XCTAssertEqual(slugOf("Scratch Terminal"), "scratch-terminal")
        XCTAssertEqual(slugOf("spotify_player"), "spotify-player")
        XCTAssertEqual(slugOf("  Notes  "), "notes")
        XCTAssertEqual(slugOf("Rack 2"), "rack-2")
    }

    func test_id_slugsNonASCIITitle() {
        XCTAssertEqual(slugOf("日本語"), "日本語")
        XCTAssertEqual(slugOf("Café Notes"), "café-notes")
    }

    func test_titleWithoutLettersOrNumbers_returnsNil() {
        XCTAssertNil(ToolFloatParser.parse("title:🎉 command:foo key:cmd+shift+j"))
        XCTAssertNil(ToolFloatParser.parse("title:\"---\" command:foo key:cmd+shift+j"))
    }

    func test_legacyIDField_isIgnored() {
        let float = ToolFloatParser.parse("id:legacy title:Notes command:foo key:cmd+shift+j")
        XCTAssertEqual(float?.id, "notes")
    }

    func test_order_parsesAndFallsBackToLineOrder() {
        XCTAssertEqual(ToolFloatParser.parse("order:7 title:x command:c key:cmd+shift+j")?.order, 7)
        XCTAssertEqual(
            ToolFloatParser.parse("title:x command:c key:cmd+shift+j", fallbackOrder: 3)?.order, 3,
            "no `order:` → the float keeps its line order, so a config predating the field is unchanged")
        XCTAssertEqual(
            ToolFloatParser.parse("order:nope title:x command:c key:cmd+shift+j", fallbackOrder: 3)?.order, 3,
            "an unparseable `order:` falls back rather than dropping a working float")
    }

    private func slugOf(_ title: String) -> String? {
        ToolFloatParser.parse("title:\"\(title)\" command:c key:cmd+shift+j")?.id
    }

    func test_persist_defaultsToEphemeral() {
        let float = ToolFloatParser.parse("title:x command:c key:cmd+shift+j")
        XCTAssertEqual(float?.persist, .ephemeral)
    }

    func test_persist_parsesEveryToken() {
        XCTAssertEqual(ToolFloatParser.parse("title:x command:c key:cmd+shift+j persist:none")?.persist, .ephemeral)
        XCTAssertEqual(ToolFloatParser.parse("title:x command:c key:cmd+shift+j persist:dir")?.persist, .directory)
    }

    func test_persist_tab_isNoLongerAMode_degradesToEphemeral() {
        let float = ToolFloatParser.parse("title:x command:c key:cmd+shift+j persist:tab")
        XCTAssertEqual(float?.persist, .ephemeral)
        XCTAssertEqual(float?.id, "x")
    }

    func test_persist_caseInsensitive() {
        XCTAssertEqual(ToolFloatParser.parse("title:x command:c key:cmd+shift+j persist:DIR")?.persist, .directory)
    }

    func test_persist_unknownValue_fallsBackToEphemeral() {
        let float = ToolFloatParser.parse("title:x command:c key:cmd+shift+j persist:banana")
        XCTAssertEqual(float?.persist, .ephemeral)
        XCTAssertEqual(float?.id, "x")
    }

    func test_persist_window_parses() {
        XCTAssertEqual(ToolFloatParser.parse("title:x command:c key:cmd+shift+j persist:window")?.persist, .window)
    }

    func test_toolbar_defaultsToShown() {
        XCTAssertEqual(
            ToolFloatParser.parse("title:x command:c key:cmd+shift+j")?.showsInToolbar, true)
    }

    func test_toolbar_false_hidesTheButton() {
        XCTAssertEqual(
            ToolFloatParser.parse("title:x command:c key:cmd+shift+j toolbar:false")?.showsInToolbar,
            false)
    }

    func test_toolbar_caseInsensitive() {
        XCTAssertEqual(
            ToolFloatParser.parse("title:x command:c key:cmd+shift+j toolbar:FALSE")?.showsInToolbar,
            false)
    }

    func test_toolbar_unknownValue_staysShown_andCollectsDiagnostic() {
        let (float, diagnostics) = ToolFloatParser.parseLine(
            "title:x command:c key:cmd+shift+j toolbar:maybe")
        XCTAssertEqual(float?.showsInToolbar, true)
        XCTAssertEqual(
            diagnostics,
            [
                ConfigDiagnostic(
                    scope: .toolFloatField(id: "x", label: "x"),
                    problem: .floatFieldInvalid(field: "toolbar:", got: "maybe", using: "true"))
            ])
    }

    func test_dir_defaultsToNil() {
        XCTAssertNil(ToolFloatParser.parse("title:x command:c key:cmd+shift+j")?.dir)
    }

    func test_dir_expandsTilde() {
        let float = ToolFloatParser.parse("title:x command:c key:cmd+shift+j dir:~/notes")
        XCTAssertEqual(float?.dir?.path, NSString(string: "~/notes").expandingTildeInPath)
    }

    func test_dir_quotedPathWithSpaces() {
        let float = ToolFloatParser.parse("title:x command:c key:cmd+shift+j dir:\"/tmp/my notes\"")
        XCTAssertEqual(float?.dir?.path, "/tmp/my notes")
    }

    func test_dirWithPersistDir_pinsALivingFloat() {
        let float = ToolFloatParser.parse("title:x command:c key:cmd+shift+j dir:/tmp persist:dir")
        XCTAssertEqual(float?.persist, .directory)
        XCTAssertEqual(float?.dir?.path, "/tmp")
    }
}
