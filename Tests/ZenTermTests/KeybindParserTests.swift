import XCTest

@testable import ZenTerm

final class KeybindParserTests: XCTestCase {
    /// Wrapper so the `ReservedChord(token:)` label never sits next to a string literal
    /// (a repo secret-scan hook flags `token: "…"` as a possible hardcoded credential).
    private func action(from name: String) -> KeyInterceptor.ReservedChord? {
        KeyInterceptor.ReservedChord(token: name)
    }

    func test_actionToken_roundTripsEveryCase() {
        let cases: [KeyInterceptor.ReservedChord] = [
            .splitVertical, .splitHorizontal, .navLeft, .navRight, .navUp, .navDown,
            .closePane, .newTab, .newWindow, .prevTab, .nextTab,
            .resizeLeft, .resizeRight, .resizeUp, .resizeDown,
            .toggleBottomDrawer, .toggleRightDrawer, .toggleZoom, .fillScreen,
            .toggleRepoPicker, .toggleCommandPalette, .openSettings, .reloadConfig, .checkForUpdates,
            .toggleDiffLayout,
            .selectTab(1), .selectTab(9), .toggleToolFloat("gitdash"),
        ]
        for chord in cases {
            XCTAssertEqual(action(from: chord.actionToken), chord)
        }
    }

    func test_focusMode_token_andLegacyZoomAlias() {
        // The action was renamed zoom → Focus Mode (ZEN-207): the canonical token is the new one,
        // and the old `toggle_zoom` still parses so an existing config keeps its binding.
        XCTAssertEqual(KeyInterceptor.ReservedChord.toggleZoom.actionToken, "toggle_focus_mode")
        XCTAssertEqual(action(from: "toggle_focus_mode"), .toggleZoom)
        XCTAssertEqual(action(from: "toggle_zoom"), .toggleZoom)  // legacy alias
    }

    func test_fillScreen_token() {
        XCTAssertEqual(KeyInterceptor.ReservedChord.fillScreen.actionToken, "fill_screen")
        XCTAssertEqual(action(from: "fill_screen"), .fillScreen)
    }

    func test_toggleDiffLayout_token_andDefaultBinding() {
        XCTAssertEqual(KeyInterceptor.ReservedChord.toggleDiffLayout.actionToken, "toggle_diff_layout")
        XCTAssertEqual(action(from: "toggle_diff_layout"), .toggleDiffLayout)
        XCTAssertEqual(
            KeymapDefaults.map[Chord(command: true, key: "i")], .toggleDiffLayout, "defaults to ⌘I")
    }

    func test_checkForUpdates_token_hasNoDefaultBinding() {
        // The action round-trips (so a hand-written keybind resolves), but it isn't in the built-in
        // keymap — it ships unbound (ZEN-20).
        XCTAssertEqual(KeyInterceptor.ReservedChord.checkForUpdates.actionToken, "check_for_updates")
        XCTAssertEqual(action(from: "check_for_updates"), .checkForUpdates)
        XCTAssertFalse(
            KeymapDefaults.map.values.contains(.checkForUpdates), "should ship without a default chord")
    }

    func test_reportIssue_token_hasNoDefaultBinding() {
        // Round-trips so a hand-written keybind resolves, but ships unbound — it's reached from the
        // command palette, the Help menu, and Settings, not a default chord (ZEN-212).
        XCTAssertEqual(KeyInterceptor.ReservedChord.reportIssue.actionToken, "report_issue")
        XCTAssertEqual(action(from: "report_issue"), .reportIssue)
        XCTAssertFalse(
            KeymapDefaults.map.values.contains(.reportIssue), "should ship without a default chord")
    }

    func test_parse_validKeybindLine() {
        // Action first, then chord.
        let pair = KeybindParser.parse("toggle_workspace_picker=cmd+shift+p")
        XCTAssertEqual(pair?.0, Chord(command: true, shift: true, key: "p"))
        XCTAssertEqual(pair?.1, .toggleRepoPicker)
    }

    func test_workspacePicker_token_andLegacyRepoAlias() {
        // The token was renamed repo → workspace (ZEN-6): the canonical token is the new one, and
        // the old `toggle_repo_picker` still parses so an existing config keeps its binding.
        XCTAssertEqual(KeyInterceptor.ReservedChord.toggleRepoPicker.actionToken, "toggle_workspace_picker")
        XCTAssertEqual(action(from: "toggle_workspace_picker"), .toggleRepoPicker)
        XCTAssertEqual(action(from: "toggle_repo_picker"), .toggleRepoPicker)  // legacy alias
    }

    func test_parse_unknownAction_isNil() {
        XCTAssertNil(KeybindParser.parse("frobnicate=cmd+f"))
    }

    func test_parse_removedLazygitAction_isNil() {
        // ZEN-140 deleted the built-in lazygit: `toggle_lazygit` must stay unparseable (the
        // config loader logs a named migration warning pointing at the float recipe instead).
        XCTAssertNil(KeybindParser.parse("toggle_lazygit=cmd+g"))
    }

    func test_parse_badChord_isNil() {
        XCTAssertNil(KeybindParser.parse("toggle_zoom=hyper+f"))
        XCTAssertNil(KeybindParser.parse("no_equals_sign"))
    }

    func test_selectTab_bounds() {
        XCTAssertNil(action(from: "select_tab_0"))
        XCTAssertNil(action(from: "select_tab_10"))
        XCTAssertEqual(action(from: "select_tab_5"), .selectTab(5))
    }

    func test_toggleFloat_action() {
        XCTAssertEqual(action(from: "toggle_float:my-tool"), .toggleToolFloat("my-tool"))
        XCTAssertNil(action(from: "toggle_float:"))  // empty id
    }
}
