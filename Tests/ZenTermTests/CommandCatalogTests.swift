import XCTest

@testable import ZenTerm

final class CommandCatalogTests: XCTestCase {
    /// The catalog reads `GeneralConfig.current` (floats and, through the keymap, chord
    /// displacement), so an unpinned suite varies by the developer's real config — a user float
    /// claiming a built-in's chord (e.g. zoom's ⌘F) strips that entry's palette glyph and
    /// fails the every-entry-has-a-shortcut assertion on that machine only.
    private var originalConfig = GeneralConfig.current

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        GeneralConfig.setCurrentForTesting(.builtIn)
    }

    override func tearDown() {
        GeneralConfig.setCurrentForTesting(originalConfig)
        super.tearDown()
    }

    func test_baseCommands_orderAndCount() {
        // User-defined tool floats are config-driven and vary by machine, so filter them out
        // and assert the fixed structural commands.
        let names = CommandCatalog.commands(tabCount: 0)
            .filter { if case .toggleToolFloat = $0.chord { return false } else { return true } }
            .map(\.title)
        XCTAssertEqual(
            names,
            [
                "Open Workspace Picker", "Diff Viewer", "Settings…", "Reload Config", "Check for Updates",
                "Report an Issue…",
                "Toggle Bottom Drawer", "Toggle Right Drawer",
                "New Tab", "Previous Tab", "Next Tab",
                "Split Horizontally", "Split Vertically",
                "Focus Pane Left", "Focus Pane Down", "Focus Pane Up", "Focus Pane Right",
                "Resize Pane Left", "Resize Pane Down", "Resize Pane Up", "Resize Pane Right",
                "Focus Mode", "Scroll Mode", "Find in Scrollback", "Find Selection",
                "Scroll Page Up", "Scroll Page Down", "Scroll to Top", "Scroll to Bottom",
                "Jump to Previous Prompt", "Jump to Next Prompt", "Scroll to Selection",
                "Clear Screen", "Select All", "Paste Selection", "Write Screen to File",
                "Close Pane",
                "Fill Screen", "Increase Font Size", "Decrease Font Size", "Reset Font Size",
            ])
    }

    /// Opening the palette runs `endModes`, which takes the find bar down, so a Find Next picked
    /// from it reaches `SearchController.navigate` with no search running and does nothing. Every
    /// time, not sometimes. A row that can never fire is worse than no row: it reads as a feature
    /// and answers with silence (ZEN-367).
    func test_findNextAndPreviousAreNotInThePalette() {
        let titles = CommandCatalog.commands(tabCount: 3).map(\.title)
        XCTAssertFalse(titles.contains("Find Next"))
        XCTAssertFalse(titles.contains("Find Previous"))
        // Find Selection stays: a mouse selection is libghostty's and survives `endModes`, so the
        // action still has something to search for when the palette hands it over.
        XCTAssertTrue(titles.contains("Find Selection"))
    }

    func test_addWorkspace_isNotInThePalette() {
        // ZEN-112 removed the ⌘P entry — adding a workspace is a Settings-only action now.
        let titles = CommandCatalog.commands(tabCount: 3).map(\.title)
        XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("add workspace") })
    }

    func test_categories_areContiguousInOrder() {
        // Grouping relies on same-category commands being adjacent, in this order.
        let categories = CommandCatalog.commands(tabCount: 3).map(\.category)
        var seen: [String] = []
        for category in categories where seen.last != category {
            XCTAssertFalse(seen.contains(category), "category \(category) is not contiguous")
            seen.append(category)
        }
        XCTAssertEqual(seen, ["Tools", "Config", "Help", "Drawers", "Tabs", "Panes", "Window"])
    }

    func test_selectTab_expandsPerTab() {
        let three = CommandCatalog.commands(tabCount: 3)
        let selects = three.filter { $0.title.hasPrefix("Select Tab") }
        XCTAssertEqual(selects.map(\.title), ["Select Tab 1", "Select Tab 2", "Select Tab 3"])
        XCTAssertEqual(selects.map(\.shortcut), ["⌘1", "⌘2", "⌘3"])
    }

    func test_selectTab_cappedAtNine() {
        let selects = CommandCatalog.commands(tabCount: 12).filter { $0.title.hasPrefix("Select Tab") }
        XCTAssertEqual(selects.count, 9)
        XCTAssertEqual(selects.last?.title, "Select Tab 9")
    }

    func test_paletteAndNewWindow_notSurfaced() {
        let titles = CommandCatalog.commands(tabCount: 5).map(\.title)
        XCTAssertFalse(titles.contains("Command Palette"))
        XCTAssertFalse(titles.contains("New Window"))
    }

    func test_openWorkspacePicker_mapsToRepoPickerChord() {
        let entry = CommandCatalog.commands(tabCount: 0).first { $0.title == "Open Workspace Picker" }
        XCTAssertNotNil(entry)
        if case .toggleRepoPicker = entry!.chord {} else { XCTFail("expected .toggleRepoPicker") }
    }

    func test_reloadConfig_mapsToReloadConfigChord() {
        let entry = CommandCatalog.commands(tabCount: 0).first { $0.title == "Reload Config" }
        XCTAssertNotNil(entry)
        if case .reloadConfig = entry!.chord {} else { XCTFail("expected .reloadConfig") }
    }

    func test_checkForUpdates_isPresent_andUnboundByDefault() {
        // Check for Updates ships without a default chord (ZEN-20), so it's in the palette but shows
        // no glyph — an unbound glyph would lie. Binding a chord fills it via the live keymap.
        let entry = CommandCatalog.commands(tabCount: 0).first { $0.title == "Check for Updates" }
        XCTAssertNotNil(entry)
        if case .checkForUpdates = entry!.chord {} else { XCTFail("expected .checkForUpdates") }
        XCTAssertEqual(entry!.shortcut, "", "Check for Updates has no default binding")
    }

    /// The palette is the whole of how these four are reached out of the box, so a row that went
    /// missing would take the action with it. ghostty puts three of them on ⌘K, ⌘J and ⌘⇧J, which
    /// are pane nav and resize here. Select All is the fourth for a different reason: ⌘A is left
    /// free for the Edit menu item ZEN-370 adds, rather than spent (ZEN-369).
    func test_theUnboundScreenActionsArePresentWithNoGlyph() {
        let entries = CommandCatalog.commands(tabCount: 3)
        for title in ["Clear Screen", "Scroll to Selection", "Write Screen to File", "Select All"] {
            let entry = entries.first { $0.title == title }
            XCTAssertNotNil(entry, "\(title) is unreachable without a palette row")
            XCTAssertEqual(entry?.shortcut, "", "\(title) has no default binding")
        }
    }

    func test_everyEntry_hasTitle_andShortcut() {
        // Every palette command shows its glyph, except the actions shipped deliberately unbound:
        // Check for Updates (ZEN-20), Report an Issue (ZEN-212), and the four screen actions whose
        // chords ZenTerm either spends elsewhere or leaves to the menu bar (ZEN-369).
        let unbound: Set<String> = [
            KeyInterceptor.ReservedChord.checkForUpdates.actionToken,
            KeyInterceptor.ReservedChord.reportIssue.actionToken,
            KeyInterceptor.ReservedChord.clearScreen.actionToken,
            KeyInterceptor.ReservedChord.scrollToSelection.actionToken,
            KeyInterceptor.ReservedChord.writeScreenFile.actionToken,
            KeyInterceptor.ReservedChord.selectAll.actionToken,
        ]
        for command in CommandCatalog.commands(tabCount: 9) {
            XCTAssertFalse(command.title.isEmpty)
            guard !unbound.contains(command.chord.actionToken) else { continue }
            XCTAssertFalse(command.shortcut.isEmpty, "\(command.title) should show a shortcut")
        }
    }
}
