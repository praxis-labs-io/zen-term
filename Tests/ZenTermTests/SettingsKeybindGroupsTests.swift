import XCTest

@testable import ZenTerm

/// The Shortcuts card's group list against the actions that claim a row.
///
/// This exists because of what it failed to catch. `groups` is hand-ordered, so seven new actions
/// shipped with a chord, a palette entry, a config token and no Settings row, and every test in the
/// suite stayed green: an action absent from that list does not render wrong, it does not render at
/// all. `isEditableInSettings` is the exhaustive switch a new case has to answer, and this is what
/// makes the answer mean something.
final class SettingsKeybindGroupsTests: XCTestCase {
    /// Every action in the groups, flattened. `selectTab` expands to nine, which is why this
    /// compares sets of tokens rather than counting.
    private var listed: Set<String> {
        Set(SettingsKeybindsSection.groups.flatMap(\.1).map(\.actionToken))
    }

    /// The editable set, spelled out. There is no `CaseIterable` to walk — `selectTab` and
    /// `toggleToolFloat` carry associated values — so the enumeration lives here, and a new case
    /// that answers `true` and is added to neither list fails below rather than shipping invisible.
    /// Shared with `CommandCatalogTests`. The enum is not `CaseIterable`, so this is the roster.
    static let everyAction: [KeyInterceptor.ReservedChord] =
        [
            .splitHorizontal, .splitVertical, .closePane, .toggleZoom,
            .toggleScrollMode, .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .jumpToPreviousPrompt, .jumpToNextPrompt, .scrollToSelection,
            .toggleSearch, .searchSelection, .findNext, .findPrevious,
            .clearScreen, .selectAll, .pasteSelection, .writeScreenFile,
            .copyScreenFilePath, .openScreenFile,
            .navLeft, .navDown, .navUp, .navRight,
            .prevPane, .nextPane,
            .resizeLeft, .resizeDown, .resizeUp, .resizeRight,
            .newTab, .newWindow, .prevTab, .nextTab, .moveTabLeft, .moveTabRight, .renameTab,
            .fillScreen, .toggleBottomDrawer, .toggleRightDrawer,
            .toggleRepoPicker, .cloneWorkspace, .removeClone, .toggleCommandPalette, .openSettings,
            .increaseFontSize, .decreaseFontSize, .resetFontSize,
            .reloadConfig, .checkForUpdates, .reportIssue, .newTool,
            .dismissToast, .dismissAllToasts,
            // Both sides of the float rule: the built-in claims a row, a user float doesn't.
            .toggleToolFloat(ToolFloat.scratch.id), .toggleToolFloat("btop"),
        ] + (1...9).map { .selectTab($0) }

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

    /// A row with no title is a blank line in the card. `CommandCatalog.spec` is exhaustive, so this
    /// cannot fail to compile, but it can return an empty string.
    func test_everyRowHasATitle() {
        for action in SettingsKeybindsSection.groups.flatMap(\.1) {
            XCTAssertFalse(CommandCatalog.spec(for: action).title.isEmpty, action.actionToken)
        }
    }

    /// One row per action. A duplicate renders twice and the two chips edit the same binding, so
    /// one of them silently shows a stale chord after the other commits.
    func test_noActionAppearsInTwoGroups() {
        let all = SettingsKeybindsSection.groups.flatMap(\.1).map(\.actionToken)
        XCTAssertEqual(all.count, Set(all).count, "an action is listed in more than one group")
    }
}
