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
                "Open Workspace Picker", "Settings…", "Reload Config",
                "Toggle Bottom Drawer", "Toggle Right Drawer",
                "New Tab", "Previous Tab", "Next Tab",
                "Split Horizontally", "Split Vertically",
                "Focus Pane Left", "Focus Pane Down", "Focus Pane Up", "Focus Pane Right",
                "Resize Pane Left", "Resize Pane Down", "Resize Pane Up", "Resize Pane Right",
                "Toggle Zoom", "Close Pane",
            ])
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
        XCTAssertEqual(seen, ["Tools", "Config", "Drawers", "Tabs", "Panes"])
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

    func test_everyEntry_hasTitle_andShortcut() {
        // Every palette command has a default key binding, so each shows its glyph. (The one former
        // exception, `.addWorkspace`, was unbound and is no longer in the palette — ZEN-112.)
        for command in CommandCatalog.commands(tabCount: 9) {
            XCTAssertFalse(command.title.isEmpty)
            XCTAssertFalse(command.shortcut.isEmpty, "\(command.title) should show a shortcut")
        }
    }
}
