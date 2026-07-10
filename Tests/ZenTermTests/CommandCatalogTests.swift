import XCTest

@testable import ZenTerm

final class CommandCatalogTests: XCTestCase {
    func test_baseCommands_orderAndCount() {
        // User-defined tool floats are config-driven and vary by machine, so filter them out
        // and assert the fixed structural commands.
        let names = CommandCatalog.commands(tabCount: 0)
            .filter { if case .toggleToolFloat = $0.chord { return false } else { return true } }
            .map(\.title)
        XCTAssertEqual(
            names,
            [
                "Open Workspace Picker", "Add Workspace…", "Open Lazygit",
                "Toggle Bottom Drawer", "Toggle Right Drawer",
                "New Tab", "Previous Tab", "Next Tab",
                "Split Horizontally", "Split Vertically",
                "Focus Pane Left", "Focus Pane Down", "Focus Pane Up", "Focus Pane Right",
                "Resize Pane Left", "Resize Pane Down", "Resize Pane Up", "Resize Pane Right",
                "Toggle Zoom", "Close Pane",
            ])
    }

    func test_categories_areContiguousInOrder() {
        // Grouping relies on same-category commands being adjacent, in this order.
        let categories = CommandCatalog.commands(tabCount: 3).map(\.category)
        var seen: [String] = []
        for category in categories where seen.last != category {
            XCTAssertFalse(seen.contains(category), "category \(category) is not contiguous")
            seen.append(category)
        }
        XCTAssertEqual(seen, ["Tools", "Drawers", "Tabs", "Panes"])
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

    func test_everyEntry_hasTitle_andBoundEntriesHaveShortcut() {
        for command in CommandCatalog.commands(tabCount: 9) {
            XCTAssertFalse(command.title.isEmpty)
            // `.addWorkspace` is deliberately unbound (opened from the palette/picker, no default
            // key), so its shortcut glyph is empty; every bound command shows its glyph. Keyed on
            // the chord, not the title, so a copy tweak can't quietly disable the check.
            if command.chord != .addWorkspace {
                XCTAssertFalse(command.shortcut.isEmpty, "\(command.title) should show a shortcut")
            }
        }
    }
}
