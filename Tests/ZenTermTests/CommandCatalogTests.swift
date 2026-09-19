import XCTest

@testable import ZenTerm

final class CommandCatalogTests: XCTestCase {
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
        let names = CommandCatalog.commands(tabCount: 0, workspaceCount: 0)
            .filter { if case .toggleToolFloat = $0.chord { return false } else { return true } }
            .map(\.title)
        XCTAssertEqual(
            names,
            [
                "Open Workspace Picker", "New Tool Float…", "Settings…", "Reload Config",
                "Check for Updates",
                "Report an Issue…",
                "Toggle Bottom Drawer", "Toggle Right Drawer",
                "New Tab", "Previous Tab", "Next Tab", "Move Tab Left", "Move Tab Right",
                "Rename Tab…", "Close Tab",
                "Split Horizontally", "Split Vertically",
                "Focus Pane Left", "Focus Pane Down", "Focus Pane Up", "Focus Pane Right",
                "Focus Previous Pane", "Focus Next Pane",
                "Resize Pane Left", "Resize Pane Down", "Resize Pane Up", "Resize Pane Right",
                "Focus Mode", "Scroll Mode", "Find in Scrollback", "Find Selection",
                "Scroll Page Up", "Scroll Page Down", "Scroll to Top", "Scroll to Bottom",
                "Jump to Previous Prompt", "Jump to Next Prompt", "Scroll to Selection",
                "Clear Screen", "Paste Selection", "Write Screen to File",
                "Write Screen to File, Copy Path", "Write Screen to File and Open",
                "Close Pane",
                "Toggle Sidebar", "Fill Screen", "Close Window",
                "Increase Font Size", "Decrease Font Size", "Reset Font Size",
                "Dismiss Notice", "Dismiss All Notices",
                "Previous Workspace", "Next Workspace",
            ])
    }

    func test_findNextAndPreviousAreNotInThePalette() {
        let titles = CommandCatalog.commands(tabCount: 3, workspaceCount: 0).map(\.title)
        XCTAssertFalse(titles.contains("Find Next"))
        XCTAssertFalse(titles.contains("Find Previous"))
        XCTAssertTrue(titles.contains("Find Selection"))
    }

    func test_selectAll_isNotInThePalette() {
        let titles = CommandCatalog.commands(tabCount: 3, workspaceCount: 0).map(\.title)
        XCTAssertFalse(titles.contains("Select All"))
    }

    func test_addWorkspace_isNotInThePalette() {
        let titles = CommandCatalog.commands(tabCount: 3, workspaceCount: 0).map(\.title)
        XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("add workspace") })
    }

    func test_categories_areContiguousInOrder() {
        let categories = CommandCatalog.commands(tabCount: 3, workspaceCount: 3).map(\.category)
        var seen: [String] = []
        for category in categories where seen.last != category {
            XCTAssertFalse(seen.contains(category), "category \(category) is not contiguous")
            seen.append(category)
        }
        XCTAssertEqual(seen, ["Tools", "Config", "Help", "Drawers", "Tabs", "Panes", "Window", "Workspaces"])
    }

    func test_selectTab_expandsPerTab() {
        let three = CommandCatalog.commands(tabCount: 3, workspaceCount: 0)
        let selects = three.filter { $0.title.hasPrefix("Select Tab") }
        XCTAssertEqual(selects.map(\.title), ["Select Tab 1", "Select Tab 2", "Select Tab 3"])
        XCTAssertEqual(selects.map(\.shortcut), ["⌘1", "⌘2", "⌘3"])
    }

    func test_selectTab_cappedAtNine() {
        let selects = CommandCatalog.commands(tabCount: 12, workspaceCount: 0).filter {
            $0.title.hasPrefix("Select Tab")
        }
        XCTAssertEqual(selects.count, 9)
        XCTAssertEqual(selects.last?.title, "Select Tab 9")
    }

    func test_paletteAndNewWindow_notSurfaced() {
        let titles = CommandCatalog.commands(tabCount: 5, workspaceCount: 0).map(\.title)
        XCTAssertFalse(titles.contains("Command Palette"))
        XCTAssertFalse(titles.contains("New Window"))
    }

    func test_openWorkspacePicker_mapsToRepoPickerChord() {
        let entry = CommandCatalog.commands(tabCount: 0, workspaceCount: 0).first {
            $0.title == "Open Workspace Picker"
        }
        XCTAssertNotNil(entry)
        if case .toggleRepoPicker = entry!.chord {} else { XCTFail("expected .toggleRepoPicker") }
    }

    func test_reloadConfig_mapsToReloadConfigChord() {
        let entry = CommandCatalog.commands(tabCount: 0, workspaceCount: 0).first { $0.title == "Reload Config" }
        XCTAssertNotNil(entry)
        if case .reloadConfig = entry!.chord {} else { XCTFail("expected .reloadConfig") }
    }

    func test_checkForUpdates_isPresent_andUnboundByDefault() {
        let entry = CommandCatalog.commands(tabCount: 0, workspaceCount: 0).first { $0.title == "Check for Updates" }
        XCTAssertNotNil(entry)
        if case .checkForUpdates = entry!.chord {} else { XCTFail("expected .checkForUpdates") }
        XCTAssertEqual(entry!.shortcut, "", "Check for Updates has no default binding")
    }

    func test_theScreenActions_showTheirChords() {
        let entries = CommandCatalog.commands(tabCount: 3, workspaceCount: 0)
        for (title, shortcut) in [
            ("Clear Screen", "⌘K"), ("Scroll to Selection", "⌘J"),
            ("Write Screen to File", "⌘⇧J"), ("Write Screen to File, Copy Path", "⌘⇧⌃J"),
            ("Write Screen to File and Open", "⌘⇧⌥J"),
        ] {
            XCTAssertEqual(entries.first { $0.title == title }?.shortcut, shortcut, title)
        }
    }

    func test_everyEntry_hasTitle_andShortcut() {
        let unbound: Set<String> = [
            KeyInterceptor.ReservedChord.checkForUpdates.actionToken,
            KeyInterceptor.ReservedChord.reportIssue.actionToken,
            KeyInterceptor.ReservedChord.newTool.actionToken,
            KeyInterceptor.ReservedChord.renameTab.actionToken,
        ]
        for command in CommandCatalog.commands(tabCount: 9, workspaceCount: 9) {
            XCTAssertFalse(command.title.isEmpty)
            guard !unbound.contains(command.chord.actionToken) else { continue }
            XCTAssertFalse(command.shortcut.isEmpty, "\(command.title) should show a shortcut")
        }
    }

    func test_everyEditableAction_isReachableFromThePalette() {
        let excluded: Set<String> = [
            "new_window",
            "toggle_command_palette",
            "search_next", "search_previous",
            "create_worktree",
            "remove_worktree",
        ]
        let listed = Set(CommandCatalog.commands(tabCount: 9, workspaceCount: 9).map(\.chord.actionToken))

        let missing =
            SettingsKeybindGroupsTests.everyAction
            .filter(\.isEditableInSettings)
            .map(\.actionToken)
            .filter { !excluded.contains($0) && !listed.contains($0) }
            .sorted()

        XCTAssertEqual(
            missing, [],
            "these have a palette title but no palette entry, so nothing on screen can run them")
    }

    func test_selectWorkspace_expandsPerOpenWorkspace_cappedAtNine() {
        let two = CommandCatalog.commands(tabCount: 1, workspaceCount: 2)
            .filter { $0.title.hasPrefix("Select Workspace") }
        XCTAssertEqual(two.map(\.title), ["Select Workspace 1", "Select Workspace 2"])
        XCTAssertEqual(two.map(\.shortcut), ["⌘⌥1", "⌘⌥2"])

        let selects = CommandCatalog.commands(tabCount: 1, workspaceCount: 12)
            .filter { $0.title.hasPrefix("Select Workspace") }
        XCTAssertEqual(selects.count, 9)
    }
}
