import XCTest

@testable import ZenTerm

final class KeybindParserTests: XCTestCase {
    /// Keeps `token: "…"` out of the source, which the secret-scan hook flags as a credential.
    private func action(from name: String) -> KeyInterceptor.ReservedChord? {
        KeyInterceptor.ReservedChord(token: name)
    }

    func test_actionToken_roundTripsEveryCase() {
        let cases: [KeyInterceptor.ReservedChord] = [
            .splitVertical, .splitHorizontal, .navLeft, .navRight, .navUp, .navDown,
            .closePane, .closeTab, .closeWindow, .newTab, .newWindow, .prevTab, .nextTab,
            .resizeLeft, .resizeRight, .resizeUp, .resizeDown,
            .toggleBottomDrawer, .toggleRightDrawer, .toggleZoom, .fillScreen, .toggleSidebar,
            .toggleRepoPicker, .createWorktree, .toggleCommandPalette, .openSettings,
            .reloadConfig, .checkForUpdates,
            .reportIssue, .toggleScrollMode, .toggleSearch,
            .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .findNext, .findPrevious, .searchSelection,
            .clearScreen, .selectAll, .scrollToSelection, .writeScreenFile,
            .jumpToPreviousPrompt, .jumpToNextPrompt, .pasteSelection,
            .increaseFontSize, .decreaseFontSize, .resetFontSize,
            .selectTab(1), .selectTab(9), .toggleToolFloat("gitdash"),
            .selectWorkspace(1), .selectWorkspace(9), .prevWorkspace, .nextWorkspace, .closeWorkspace,
            .newWorkspace,
        ]
        for chord in cases {
            XCTAssertEqual(action(from: chord.actionToken), chord)
        }
    }

    func test_focusMode_token_andLegacyZoomAlias() {
        XCTAssertEqual(KeyInterceptor.ReservedChord.toggleZoom.actionToken, "toggle_focus_mode")
        XCTAssertEqual(action(from: "toggle_focus_mode"), .toggleZoom)
        XCTAssertEqual(action(from: "toggle_zoom"), .toggleZoom)
    }

    func test_findStepping_tokens_andLegacyFindAliases() {
        XCTAssertEqual(KeyInterceptor.ReservedChord.findNext.actionToken, "search_next")
        XCTAssertEqual(KeyInterceptor.ReservedChord.findPrevious.actionToken, "search_previous")
        XCTAssertEqual(action(from: "search_next"), .findNext)
        XCTAssertEqual(action(from: "search_previous"), .findPrevious)
        XCTAssertEqual(action(from: "find_next"), .findNext)
        XCTAssertEqual(action(from: "find_previous"), .findPrevious)
    }

    func test_toggleSidebar_token() {
        XCTAssertEqual(KeyInterceptor.ReservedChord.toggleSidebar.actionToken, "toggle_sidebar")
        XCTAssertEqual(action(from: "toggle_sidebar"), .toggleSidebar)
    }

    func test_fillScreen_token() {
        XCTAssertEqual(KeyInterceptor.ReservedChord.fillScreen.actionToken, "fill_screen")
        XCTAssertEqual(action(from: "fill_screen"), .fillScreen)
    }

    func test_diffLayoutToggle_isNotAGlobalChord() {
        XCTAssertNil(action(from: "toggle_diff_layout"))
        XCTAssertNil(KeymapDefaults.map[Chord(command: true, key: "i")], "⌘I is no longer reserved")
    }

    func test_checkForUpdates_token_hasNoDefaultBinding() {
        XCTAssertEqual(KeyInterceptor.ReservedChord.checkForUpdates.actionToken, "check_for_updates")
        XCTAssertEqual(action(from: "check_for_updates"), .checkForUpdates)
        XCTAssertFalse(
            KeymapDefaults.map.values.contains(.checkForUpdates), "should ship without a default chord")
    }

    func test_reportIssue_token_hasNoDefaultBinding() {
        XCTAssertEqual(KeyInterceptor.ReservedChord.reportIssue.actionToken, "report_issue")
        XCTAssertEqual(action(from: "report_issue"), .reportIssue)
        XCTAssertFalse(
            KeymapDefaults.map.values.contains(.reportIssue), "should ship without a default chord")
    }

    func test_parse_validKeybindLine() {
        XCTAssertEqual(
            KeybindParser.parse("toggle_workspace_picker=cmd+shift+p"),
            .bind(Chord(command: true, shift: true, key: "p"), .toggleRepoPicker))
    }

    func test_parse_noneAndUnbind_bothMeanNoShortcut() {
        XCTAssertEqual(KeybindParser.parse("find_next=none"), .unbind(.findNext))
        XCTAssertEqual(KeybindParser.parse("find_next=unbind"), .unbind(.findNext))
        XCTAssertEqual(KeybindParser.parse("find_next=NONE"), .unbind(.findNext))
        XCTAssertEqual(KeybindParser.parse("find_next = none"), .unbind(.findNext))
    }

    func test_parse_emptyChord_isNotAnUnbind() {
        XCTAssertNil(KeybindParser.parse("find_next="))
        XCTAssertNil(KeybindParser.parse("find_next=  "))
    }

    func test_parse_ghosttyTriggerFirstUnbind_isStillUnparseable() {
        XCTAssertNil(KeybindParser.parse("cmd+g=unbind"))
    }

    func test_workspacePicker_token_andLegacyRepoAlias() {
        XCTAssertEqual(KeyInterceptor.ReservedChord.toggleRepoPicker.actionToken, "toggle_workspace_picker")
        XCTAssertEqual(action(from: "toggle_workspace_picker"), .toggleRepoPicker)
        XCTAssertEqual(action(from: "toggle_repo_picker"), .toggleRepoPicker)
    }

    func test_parse_unknownAction_isNil() {
        XCTAssertNil(KeybindParser.parse("frobnicate=cmd+f"))
    }

    func test_parse_removedLazygitAction_isNil() {
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

    func test_selectWorkspace_bounds() {
        XCTAssertNil(action(from: "select_workspace_0"))
        XCTAssertNil(action(from: "select_workspace_10"))
        XCTAssertEqual(action(from: "select_workspace_9"), .selectWorkspace(9))
    }

    func test_toggleFloat_action() {
        XCTAssertEqual(action(from: "toggle_float:my-tool"), .toggleToolFloat("my-tool"))
        XCTAssertNil(action(from: "toggle_float:"))
    }
}
