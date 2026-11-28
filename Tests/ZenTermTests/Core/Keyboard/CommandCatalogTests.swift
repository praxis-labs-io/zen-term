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

    func test_aConnectedHost_listsDisconnect_inPlaceOfCloseWorkspace() {
        let titles = CommandCatalog.commands(tabCount: 1, workspaceCount: 1, onHost: true).map(\.title)

        XCTAssertTrue(titles.contains("Disconnect"))
        XCTAssertFalse(titles.contains("Close Workspace"))
        let disconnect = CommandCatalog.commands(tabCount: 1, workspaceCount: 1, onHost: true)
            .first { $0.title == "Disconnect" }
        XCTAssertEqual(disconnect?.chord, .closeWorkspace)
        XCTAssertEqual(disconnect?.shortcut, CommandCatalog.spec(for: .closeWorkspace).shortcut)
    }

    func test_renameWorkspace_isListedUnbound_andAbsentOnAHost() {
        let entry = CommandCatalog.commands(tabCount: 1, workspaceCount: 1).first { $0.chord == .renameWorkspace }

        XCTAssertEqual(entry?.title, "Rename Workspace…")
        XCTAssertEqual(entry?.shortcut, "", "Rename Workspace has no default binding")
        for tabCount in [0, 1] {
            let onHost = CommandCatalog.commands(tabCount: tabCount, workspaceCount: 1, onHost: true)
            XCTAssertFalse(onHost.contains { $0.chord == .renameWorkspace }, "a host's name is its Settings name")
        }
    }

    func test_aHostsConnectScreen_listsEditHost_inPlaceOfFindSelection() {
        let connect = CommandCatalog.commands(tabCount: 0, workspaceCount: 0, onHost: true)
        let terminal = CommandCatalog.commands(tabCount: 1, workspaceCount: 1, onHost: true)

        XCTAssertEqual(connect.first { $0.chord == .searchSelection }?.title, "Edit Host…")
        XCTAssertEqual(
            terminal.first { $0.chord == .searchSelection }?.title, CommandCatalog.spec(for: .searchSelection).title)
    }

    func test_aHostsConnectScreen_listsNeitherDisconnectNorCloseWorkspace() {
        let titles = CommandCatalog.commands(tabCount: 0, workspaceCount: 0, onHost: true).map(\.title)

        XCTAssertFalse(titles.contains("Disconnect"), "there is nothing to disconnect")
        XCTAssertFalse(titles.contains("Close Workspace"))
    }

    func test_baseCommands_orderAndCount() {
        let names = CommandCatalog.commands(tabCount: 0, workspaceCount: 0)
            .filter { if case .toggleToolFloat = $0.chord { return false } else { return true } }
            .map(\.title)
        XCTAssertEqual(
            names,
            [
                "Open Workspace Picker", "New Workspace", "Previous Workspace", "Next Workspace",
                "Rename Workspace…",
                "Jump to Waiting Agent",
                "Open Agent Picker",
                "Close Workspace",
                "New Tab", "Previous Tab", "Next Tab", "Move Tab Left", "Move Tab Right",
                "Rename Tab…",
                "Toggle Bottom Drawer", "Toggle Right Drawer",
                "Close Tab",
                "Split Horizontally", "Split Vertically",
                "Focus Pane Left", "Focus Pane Down", "Focus Pane Up", "Focus Pane Right",
                "Focus Previous Pane", "Focus Next Pane",
                "Resize Pane Left", "Resize Pane Down", "Resize Pane Up", "Resize Pane Right",
                "Focus Mode", "Close Pane",
                "Scroll Mode", "Find in Scrollback", "Find Selection",
                "Scroll Page Up", "Scroll Page Down", "Scroll to Top", "Scroll to Bottom",
                "Jump to Previous Prompt", "Jump to Next Prompt", "Scroll to Selection",
                "Clear Screen", "Paste Selection", "Write Screen to File",
                "Write Screen to File, Copy Path", "Write Screen to File and Open",
                "New Tool Float…",
                "Fill Screen", "Toggle Sidebar", "Focus Sidebar", "Close Window",
                "Settings…", "Reload Config", "Check for Updates",
                "Increase Font Size", "Decrease Font Size", "Reset Font Size",
                "Dismiss Notice", "Dismiss All Notices", "Report an Issue…",
                "Keep Awake", "Keep Awake for 1 Hour", "Keep Mac and Display Awake",
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
        let categories = CommandCatalog.commands(tabCount: 3, workspaceCount: 3).map(\.category.title)
        var seen: [String] = []
        for category in categories where seen.last != category {
            XCTAssertFalse(seen.contains(category), "category \(category) is not contiguous")
            seen.append(category)
        }
        XCTAssertEqual(seen, ["Workspaces", "Tabs", "Panes", "Terminal", "Tools", "Window", "App"])
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
            KeyInterceptor.ReservedChord.renameWorkspace.actionToken,
            KeyInterceptor.ReservedChord.focusSidebar.actionToken,
            KeyInterceptor.ReservedChord.keepAwake.actionToken,
            KeyInterceptor.ReservedChord.turnOffKeepAwake.actionToken,
            KeyInterceptor.ReservedChord.keepAwakeUntilAgentsFinish.actionToken,
            KeyInterceptor.ReservedChord.keepAwakeForOneHour.actionToken,
            KeyInterceptor.ReservedChord.keepAwakeWithDisplay.actionToken,
        ]
        for command in CommandCatalog.commands(
            tabCount: 9, workspaceCount: 9, keepAwakeIsOn: true, agentsWorking: true)
        {
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
        let listed = Set(
            CommandCatalog.commands(tabCount: 9, workspaceCount: 9, keepAwakeIsOn: true, agentsWorking: true)
                .map(\.chord.actionToken))

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
        XCTAssertEqual(two.map(\.shortcut), ["⌘⌃1", "⌘⌃2"])

        let selects = CommandCatalog.commands(tabCount: 1, workspaceCount: 12)
            .filter { $0.title.hasPrefix("Select Workspace") }
        XCTAssertEqual(selects.count, 9)
    }

    func test_keepAwake_listsTurnOffOnlyWhileOn_andUntilAgentsFinishOnlyWhileOneWorks() {
        func chords(on: Bool, working: Bool) -> [KeyInterceptor.ReservedChord] {
            CommandCatalog.commands(tabCount: 1, workspaceCount: 1, keepAwakeIsOn: on, agentsWorking: working)
                .map(\.chord)
        }
        let always: [KeyInterceptor.ReservedChord] = [.keepAwake, .keepAwakeForOneHour, .keepAwakeWithDisplay]

        XCTAssertTrue(Set(always).isSubset(of: chords(on: false, working: false)))
        XCTAssertFalse(chords(on: false, working: false).contains(.turnOffKeepAwake))
        XCTAssertFalse(chords(on: false, working: false).contains(.keepAwakeUntilAgentsFinish))
        XCTAssertTrue(chords(on: true, working: false).contains(.turnOffKeepAwake))
        XCTAssertTrue(chords(on: false, working: true).contains(.keepAwakeUntilAgentsFinish))
    }

    func test_keepAwakeCommands_areAppCommands_withNoDefaultShortcut() {
        let chords: [KeyInterceptor.ReservedChord] = [
            .keepAwake, .turnOffKeepAwake, .keepAwakeUntilAgentsFinish, .keepAwakeForOneHour, .keepAwakeWithDisplay,
        ]
        for chord in chords {
            let spec = CommandCatalog.spec(for: chord)
            XCTAssertEqual(spec.category, .app, spec.title)
            XCTAssertEqual(spec.shortcut, "", spec.title)
            XCTAssertTrue(chord.isEditableInSettings, spec.title)
            XCTAssertEqual(KeyInterceptor.ReservedChord(token: chord.actionToken), chord, spec.title)
        }
    }
}
