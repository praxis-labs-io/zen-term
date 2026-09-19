import XCTest

@testable import ZenTerm

final class SettingsKeybindGroupsTests: XCTestCase {
    private var listed: Set<String> {
        Set(SettingsKeybindsSection.groups.flatMap(\.1).map(\.actionToken))
    }

    static let everyAction: [KeyInterceptor.ReservedChord] =
        [
            .splitHorizontal, .splitVertical, .closePane, .closeTab, .closeWindow, .toggleZoom,
            .toggleScrollMode, .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .jumpToPreviousPrompt, .jumpToNextPrompt, .scrollToSelection,
            .toggleSearch, .searchSelection, .findNext, .findPrevious,
            .clearScreen, .selectAll, .pasteSelection, .writeScreenFile,
            .copyScreenFilePath, .openScreenFile,
            .navLeft, .navDown, .navUp, .navRight,
            .prevPane, .nextPane,
            .resizeLeft, .resizeDown, .resizeUp, .resizeRight,
            .newTab, .newWindow, .prevTab, .nextTab, .moveTabLeft, .moveTabRight, .renameTab,
            .fillScreen, .toggleSidebar, .focusSidebar, .toggleBottomDrawer, .toggleRightDrawer,
            .toggleRepoPicker, .newWorkspace, .createWorktree, .removeWorktree, .toggleCommandPalette,
            .openSettings,
            .increaseFontSize, .decreaseFontSize, .resetFontSize,
            .reloadConfig, .checkForUpdates, .reportIssue, .newTool,
            .dismissToast, .dismissAllToasts,
            .toggleToolFloat(ToolFloat.scratch.id), .toggleToolFloat("btop"),
            .prevWorkspace, .nextWorkspace, .closeWorkspace,
        ] + (1...9).map { .selectTab($0) } + (1...9).map { .selectWorkspace($0) }

    func test_everyEditableActionHasARow() {
        let editable = Set(
            Self.everyAction.filter(\.isEditableInSettings).map(\.actionToken))

        XCTAssertEqual(
            editable.subtracting(listed), [],
            "these say they are editable and the Shortcuts card has no row for them, so they are "
                + "unrebindable and nothing on screen says why")
        XCTAssertEqual(
            listed.subtracting(editable), [],
            "these have a row that isEditableInSettings says should not exist")
    }

    func test_everyRowHasATitle() {
        for action in SettingsKeybindsSection.groups.flatMap(\.1) {
            XCTAssertFalse(CommandCatalog.spec(for: action).title.isEmpty, action.actionToken)
        }
    }

    func test_noActionAppearsInTwoGroups() {
        let all = SettingsKeybindsSection.groups.flatMap(\.1).map(\.actionToken)
        XCTAssertEqual(all.count, Set(all).count, "an action is listed in more than one group")
    }
}
