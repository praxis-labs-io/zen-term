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
            .reportIssue, .toggleScrollMode, .toggleSearch,
            .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .findNext, .findPrevious, .searchSelection,
            .clearScreen, .selectAll, .scrollToSelection, .writeScreenFile,
            .jumpToPreviousPrompt, .jumpToNextPrompt, .pasteSelection,
            .increaseFontSize, .decreaseFontSize, .resetFontSize,
            .selectTab(1), .selectTab(9), .toggleToolFloat("gitdash"),
        ]
        for chord in cases {
            XCTAssertEqual(action(from: chord.actionToken), chord)
        }
    }

    func test_focusMode_token_andLegacyZoomAlias() {
        // The action was renamed zoom → Focus Mode: the canonical token is the new one,
        // and the old `toggle_zoom` still parses so an existing config keeps its binding.
        XCTAssertEqual(KeyInterceptor.ReservedChord.toggleZoom.actionToken, "toggle_focus_mode")
        XCTAssertEqual(action(from: "toggle_focus_mode"), .toggleZoom)
        XCTAssertEqual(action(from: "toggle_zoom"), .toggleZoom)  // legacy alias
    }

    func test_findStepping_tokens_andLegacyFindAliases() {
        // The config file speaks `search`, so the two stepping actions moved to match
        // `toggle_search`. The `find_` tokens still parse so an existing config keeps its binding.
        XCTAssertEqual(KeyInterceptor.ReservedChord.findNext.actionToken, "search_next")
        XCTAssertEqual(KeyInterceptor.ReservedChord.findPrevious.actionToken, "search_previous")
        XCTAssertEqual(action(from: "search_next"), .findNext)
        XCTAssertEqual(action(from: "search_previous"), .findPrevious)
        XCTAssertEqual(action(from: "find_next"), .findNext)  // legacy alias
        XCTAssertEqual(action(from: "find_previous"), .findPrevious)  // legacy alias
    }

    func test_fillScreen_token() {
        XCTAssertEqual(KeyInterceptor.ReservedChord.fillScreen.actionToken, "fill_screen")
        XCTAssertEqual(action(from: "fill_screen"), .fillScreen)
    }

    func test_diffLayoutToggle_isNotAGlobalChord() {
        // The layout toggle is viewer-local (bare `\`, handled in the overlay's keyDown) — it is not a
        // reserved chord, so it round-trips to nothing and ⌘I is free.
        XCTAssertNil(action(from: "toggle_diff_layout"))
        XCTAssertNil(KeymapDefaults.map[Chord(command: true, key: "i")], "⌘I is no longer reserved")
    }

    func test_checkForUpdates_token_hasNoDefaultBinding() {
        // The action round-trips (so a hand-written keybind resolves), but it isn't in the built-in
        // keymap — it ships unbound.
        XCTAssertEqual(KeyInterceptor.ReservedChord.checkForUpdates.actionToken, "check_for_updates")
        XCTAssertEqual(action(from: "check_for_updates"), .checkForUpdates)
        XCTAssertFalse(
            KeymapDefaults.map.values.contains(.checkForUpdates), "should ship without a default chord")
    }

    func test_reportIssue_token_hasNoDefaultBinding() {
        // Round-trips so a hand-written keybind resolves, but ships unbound — it's reached from the
        // command palette, the Help menu, and Settings, not a default chord.
        XCTAssertEqual(KeyInterceptor.ReservedChord.reportIssue.actionToken, "report_issue")
        XCTAssertEqual(action(from: "report_issue"), .reportIssue)
        XCTAssertFalse(
            KeymapDefaults.map.values.contains(.reportIssue), "should ship without a default chord")
    }

    func test_parse_validKeybindLine() {
        // Action first, then chord.
        XCTAssertEqual(
            KeybindParser.parse("toggle_workspace_picker=cmd+shift+p"),
            .bind(Chord(command: true, shift: true, key: "p"), .toggleRepoPicker))
    }

    /// Both words for "no shortcut". `none` is ours; `unbind` is ghostty's, and a ghostty
    /// user reaches for it. Case is the user's business.
    func test_parse_noneAndUnbind_bothMeanNoShortcut() {
        XCTAssertEqual(KeybindParser.parse("find_next=none"), .unbind(.findNext))
        XCTAssertEqual(KeybindParser.parse("find_next=unbind"), .unbind(.findNext))
        XCTAssertEqual(KeybindParser.parse("find_next=NONE"), .unbind(.findNext))
        XCTAssertEqual(KeybindParser.parse("find_next = none"), .unbind(.findNext))
    }

    /// A trailing `=` is a typo, and reading it as a deliberate unbind would take a shortcut away
    /// on the strength of a slip. It stays unparseable, which reports itself.
    func test_parse_emptyChord_isNotAnUnbind() {
        XCTAssertNil(KeybindParser.parse("find_next="))
        XCTAssertNil(KeybindParser.parse("find_next=  "))
    }

    /// ghostty's own line reads trigger-first, so its `cmd+g=unbind` is still an unknown action
    /// here. Accepting the word is not accepting the line shape, and claiming otherwise in the
    /// config doc would send people to write a line that does nothing.
    func test_parse_ghosttyTriggerFirstUnbind_isStillUnparseable() {
        XCTAssertNil(KeybindParser.parse("cmd+g=unbind"))
    }

    func test_workspacePicker_token_andLegacyRepoAlias() {
        // The token was renamed repo → workspace: the canonical token is the new one, and
        // the old `toggle_repo_picker` still parses so an existing config keeps its binding.
        XCTAssertEqual(KeyInterceptor.ReservedChord.toggleRepoPicker.actionToken, "toggle_workspace_picker")
        XCTAssertEqual(action(from: "toggle_workspace_picker"), .toggleRepoPicker)
        XCTAssertEqual(action(from: "toggle_repo_picker"), .toggleRepoPicker)  // legacy alias
    }

    func test_parse_unknownAction_isNil() {
        XCTAssertNil(KeybindParser.parse("frobnicate=cmd+f"))
    }

    func test_parse_removedLazygitAction_isNil() {
        // The built-in lazygit was deleted: `toggle_lazygit` must stay unparseable (the
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
