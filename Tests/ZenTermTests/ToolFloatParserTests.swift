import XCTest

@testable import ZenTerm

final class ToolFloatParserTests: XCTestCase {
    func test_minimalLine_usesDefaults() {
        let float = ToolFloatParser.parse("title:x command:foo key:cmd+shift+j")
        XCTAssertEqual(float?.id, "x")
        XCTAssertEqual(float?.command, "foo")
        XCTAssertEqual(float?.title, "x")
        XCTAssertEqual(float?.icon, "square.on.square")
        XCTAssertEqual(float?.widthFraction, 0.85)
        XCTAssertEqual(float?.heightFraction, 0.85)
        XCTAssertEqual(float?.requiresGitRepo, false)
        XCTAssertEqual(float?.shortcut, "⌘⇧J")
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
        XCTAssertEqual(float?.widthFraction, 1.0)  // 5 → clamped to 1.0
        XCTAssertEqual(float?.heightFraction, 0.2)  // 0 → clamped to 0.2 (never an invalid multiplier)
    }

    func test_git_caseInsensitive() {
        XCTAssertEqual(ToolFloatParser.parse("title:x command:c key:cmd+shift+j git:True")?.requiresGitRepo, true)
        XCTAssertEqual(ToolFloatParser.parse("title:x command:c key:cmd+shift+j git:TRUE")?.requiresGitRepo, true)
    }

    func test_missingRequiredFields_returnNil() {
        XCTAssertNil(ToolFloatParser.parse("command:foo key:cmd+shift+j"))  // no title
        XCTAssertNil(ToolFloatParser.parse("title:x key:cmd+shift+j"))  // no command
        XCTAssertNil(ToolFloatParser.parse("title:x command:foo"))  // no key
        XCTAssertNil(ToolFloatParser.parse("title:x command:foo key:nope+"))  // unparseable key
    }

    // MARK: dropped-line diagnostics (ZEN-7)
    //
    // A dropped float never becomes a row, so `parseLine`'s diagnostic is the only way its reason
    // reaches the user (the Tools notice + the reload toast). `parse` swallows it; `parseLine` carries
    // it, labelled by the line's title so the notice names the right line.

    func test_parseLine_missingTitle_reportsMissingTitle() {
        let result = ToolFloatParser.parseLine("command:foo key:cmd+shift+j")
        XCTAssertNil(result.float)
        XCTAssertEqual(
            result.diagnostic,
            ConfigDiagnostic(scope: .toolFloat(label: "a float line"), problem: .floatMissingField("title:")))
    }

    func test_parseLine_missingCommand_reportsMissingCommandLabelledByTitle() {
        let result = ToolFloatParser.parseLine("title:Notes key:cmd+shift+n")
        XCTAssertNil(result.float)
        XCTAssertEqual(
            result.diagnostic,
            ConfigDiagnostic(scope: .toolFloat(label: "Notes"), problem: .floatMissingField("command:")))
    }

    func test_parseLine_missingKey_reportsMissingKey() {
        let result = ToolFloatParser.parseLine("title:Notes command:foo")
        XCTAssertNil(result.float)
        XCTAssertEqual(
            result.diagnostic,
            ConfigDiagnostic(scope: .toolFloat(label: "Notes"), problem: .floatMissingField("key:")))
    }

    func test_parseLine_emptyKey_reportsMissingNotUnusable() {
        // `key:` with no value is missing, not an unusable key — reporting `.floatUnusableKey("")`
        // would name a blank chord and read as a keyboard limitation.
        let result = ToolFloatParser.parseLine("title:Notes command:foo key:")
        XCTAssertNil(result.float)
        XCTAssertEqual(
            result.diagnostic,
            ConfigDiagnostic(scope: .toolFloat(label: "Notes"), problem: .floatMissingField("key:")))
    }

    func test_parseLine_unparseableKey_reportsUnusableKey() {
        let result = ToolFloatParser.parseLine("title:Notes command:foo key:nope+")
        XCTAssertNil(result.float)
        XCTAssertEqual(
            result.diagnostic,
            ConfigDiagnostic(scope: .toolFloat(label: "Notes"), problem: .floatUnusableKey("nope+")))
    }

    func test_parseLine_validFloat_hasNoDiagnostic() {
        let result = ToolFloatParser.parseLine("title:x command:c key:cmd+shift+j")
        XCTAssertNotNil(result.float)
        XCTAssertNil(result.diagnostic)
    }

    // MARK: identity (ZEN-145)

    /// The title is the source of truth; the id is its slug and is never authored. Renaming a float is
    /// therefore the only thing that can change its id.
    func test_id_isSlugOfTitle() {
        XCTAssertEqual(slugOf("Open GitDash"), "open-gitdash")
        XCTAssertEqual(slugOf("BTop"), "btop")
        XCTAssertEqual(slugOf("Scratch Terminal"), "scratch-terminal")
        XCTAssertEqual(slugOf("spotify_player"), "spotify-player")  // runs of punctuation collapse
        XCTAssertEqual(slugOf("  Notes  "), "notes")  // and never lead or trail with a dash
        XCTAssertEqual(slugOf("Rack 2"), "rack-2")  // digits are kept, not treated as separators
    }

    /// `isLetter`/`isNumber`, not an ASCII range — a CJK title must slug to itself, not to nothing,
    /// which would make the float unaddressable and drop the line.
    func test_id_slugsNonASCIITitle() {
        XCTAssertEqual(slugOf("日本語"), "日本語")
        XCTAssertEqual(slugOf("Café Notes"), "café-notes")
    }

    /// A title with nothing to slug leaves no id to key the float's keybind, live instance, or config
    /// line by — so the line drops rather than minting a float nothing could ever address.
    func test_titleWithoutLettersOrNumbers_returnsNil() {
        XCTAssertNil(ToolFloatParser.parse("title:🎉 command:foo key:cmd+shift+j"))
        XCTAssertNil(ToolFloatParser.parse("title:\"---\" command:foo key:cmd+shift+j"))
    }

    /// `id:` is a dead field from before ZEN-145. It must be inert — silently ignored like any unknown
    /// field — never resurrected as an identity that could disagree with the title's slug.
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

    /// `tab` was cut before it ever shipped (daily driving showed tab scoping is the wrong axis —
    /// the ZEN-77 pivot). A config that says it must degrade like any unknown token, keeping the float.
    func test_persist_tab_isNoLongerAMode_degradesToEphemeral() {
        let float = ToolFloatParser.parse("title:x command:c key:cmd+shift+j persist:tab")
        XCTAssertEqual(float?.persist, .ephemeral)
        XCTAssertEqual(float?.id, "x")
    }

    func test_persist_caseInsensitive() {
        XCTAssertEqual(ToolFloatParser.parse("title:x command:c key:cmd+shift+j persist:DIR")?.persist, .directory)
    }

    /// An unknown value must not drop the whole float — the float still works, just ephemerally.
    func test_persist_unknownValue_fallsBackToEphemeral() {
        let float = ToolFloatParser.parse("title:x command:c key:cmd+shift+j persist:banana")
        XCTAssertEqual(float?.persist, .ephemeral)
        XCTAssertEqual(float?.id, "x")
    }

    /// ZEN-141 landed `window`, so it must now parse rather than degrade to `none` — the mode is
    /// what keeps a tool alive for the whole window, and silently ephemeral would look like
    /// persistence failing.
    func test_persist_window_parses() {
        XCTAssertEqual(ToolFloatParser.parse("title:x command:c key:cmd+shift+j persist:window")?.persist, .window)
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

    /// A pinned dir gives `persist:dir` a fixed identity — the instance never re-anchors. That's
    /// the intended way to keep a tool alive at one place, so both fields parse together cleanly.
    func test_dirWithPersistDir_pinsALivingFloat() {
        let float = ToolFloatParser.parse("title:x command:c key:cmd+shift+j dir:/tmp persist:dir")
        XCTAssertEqual(float?.persist, .directory)
        XCTAssertEqual(float?.dir?.path, "/tmp")
    }
}
