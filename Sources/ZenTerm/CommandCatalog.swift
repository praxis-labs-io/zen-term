import Foundation

struct PaletteCommand {
    let title: String
    let shortcut: String
    let category: String
    let chord: KeyInterceptor.ReservedChord
}

enum CommandCatalog {
    private enum Category {
        static let panes = "Panes"
        static let tabs = "Tabs"
        static let drawers = "Drawers"
        static let window = "Window"
        static let tools = "Tools"
        static let config = "Config"
        static let help = "Help"
    }

    static func spec(for chord: KeyInterceptor.ReservedChord) -> PaletteCommand {
        let glyph = displayGlyph(for: chord)
        switch chord {
        case .splitHorizontal: return pane("Split Horizontally", glyph, chord)
        case .splitVertical: return pane("Split Vertically", glyph, chord)
        case .navLeft: return pane("Focus Pane Left", glyph, chord)
        case .navDown: return pane("Focus Pane Down", glyph, chord)
        case .navUp: return pane("Focus Pane Up", glyph, chord)
        case .navRight: return pane("Focus Pane Right", glyph, chord)
        case .prevPane: return pane("Focus Previous Pane", glyph, chord)
        case .nextPane: return pane("Focus Next Pane", glyph, chord)
        case .resizeLeft: return pane("Resize Pane Left", glyph, chord)
        case .resizeDown: return pane("Resize Pane Down", glyph, chord)
        case .resizeUp: return pane("Resize Pane Up", glyph, chord)
        case .resizeRight: return pane("Resize Pane Right", glyph, chord)
        case .toggleZoom: return pane("Focus Mode", glyph, chord)
        case .fillScreen: return window("Fill Screen", glyph, chord)
        case .toggleSidebar: return window("Toggle Sidebar", glyph, chord)
        case .closePane: return pane("Close Pane", glyph, chord)
        case .closeTab: return tab("Close Tab", glyph, chord)
        case .closeWindow: return window("Close Window", glyph, chord)
        case .newTab: return tab("New Tab", glyph, chord)
        case .prevTab: return tab("Previous Tab", glyph, chord)
        case .nextTab: return tab("Next Tab", glyph, chord)
        case .selectTab(let n): return tab("Select Tab \(n)", glyph, chord)
        case .moveTabLeft: return tab("Move Tab Left", glyph, chord)
        case .moveTabRight: return tab("Move Tab Right", glyph, chord)
        case .renameTab: return tab("Rename Tab…", glyph, chord)
        case .toggleBottomDrawer: return drawer("Toggle Bottom Drawer", glyph, chord)
        case .toggleRightDrawer: return drawer("Toggle Right Drawer", glyph, chord)
        case .toggleToolFloat(let id): return tool(ToolFloatCatalog.byID(id)?.title ?? id, glyph, chord)
        case .toggleRepoPicker: return tool("Open Workspace Picker", glyph, chord)
        case .openSettings: return config("Settings…", glyph, chord)
        case .reloadConfig: return config("Reload Config", glyph, chord)
        case .checkForUpdates: return config("Check for Updates", glyph, chord)
        case .reportIssue: return help("Report an Issue…", glyph, chord)
        case .newTool: return tool("New Tool Float…", glyph, chord)
        case .increaseFontSize: return window("Increase Font Size", glyph, chord)
        case .decreaseFontSize: return window("Decrease Font Size", glyph, chord)
        case .resetFontSize: return window("Reset Font Size", glyph, chord)
        case .toggleScrollMode: return pane("Scroll Mode", glyph, chord)
        case .toggleSearch: return pane("Find in Scrollback", glyph, chord)
        case .scrollToTop: return pane("Scroll to Top", glyph, chord)
        case .scrollToBottom: return pane("Scroll to Bottom", glyph, chord)
        case .scrollPageUp: return pane("Scroll Page Up", glyph, chord)
        case .scrollPageDown: return pane("Scroll Page Down", glyph, chord)
        case .searchSelection: return pane("Find Selection", glyph, chord)
        case .clearScreen: return pane("Clear Screen", glyph, chord)
        case .scrollToSelection: return pane("Scroll to Selection", glyph, chord)
        case .jumpToPreviousPrompt: return pane("Jump to Previous Prompt", glyph, chord)
        case .jumpToNextPrompt: return pane("Jump to Next Prompt", glyph, chord)
        case .pasteSelection: return pane("Paste Selection", glyph, chord)
        case .writeScreenFile: return pane("Write Screen to File", glyph, chord)
        case .copyScreenFilePath: return pane("Write Screen to File, Copy Path", glyph, chord)
        case .openScreenFile: return pane("Write Screen to File and Open", glyph, chord)
        case .dismissToast: return window("Dismiss Notice", glyph, chord)
        case .dismissAllToasts: return window("Dismiss All Notices", glyph, chord)
        case .newWindow: return tab("New Window", glyph, chord)
        case .selectAll: return pane("Select All", glyph, chord)
        case .toggleCommandPalette: return tool("Command Palette", glyph, chord)
        case .findNext: return pane("Find Next", glyph, chord)
        case .createWorktree: return tool("New Worktree…", glyph, chord)
        case .removeWorktree: return tool("Remove Worktree…", glyph, chord)
        case .findPrevious: return pane("Find Previous", glyph, chord)
        }
    }

    private static func displayGlyph(for chord: KeyInterceptor.ReservedChord) -> String {
        Chord.displayed(chord, in: GeneralConfig.current.keymap)?.displayGlyph ?? ""
    }

    static func commands(tabCount: Int) -> [PaletteCommand] {
        var chords: [KeyInterceptor.ReservedChord] = [.toggleRepoPicker]
        chords += ToolFloatCatalog.all.map { .toggleToolFloat($0.id) }
        chords += [.newTool]
        chords += [.openSettings, .reloadConfig, .checkForUpdates, .reportIssue]
        chords += [
            .toggleBottomDrawer, .toggleRightDrawer,
            .newTab, .prevTab, .nextTab, .moveTabLeft, .moveTabRight, .renameTab, .closeTab,
        ]
        if tabCount > 0 {
            chords += (1...min(tabCount, 9)).map { .selectTab($0) }
        }
        chords += [
            .splitHorizontal, .splitVertical,
            .navLeft, .navDown, .navUp, .navRight, .prevPane, .nextPane,
            .resizeLeft, .resizeDown, .resizeUp, .resizeRight,
            .toggleZoom, .toggleScrollMode, .toggleSearch, .searchSelection,
            .scrollPageUp, .scrollPageDown, .scrollToTop, .scrollToBottom,
            .jumpToPreviousPrompt, .jumpToNextPrompt, .scrollToSelection,
            .clearScreen, .pasteSelection, .writeScreenFile,
            .copyScreenFilePath, .openScreenFile,
            .closePane,
        ]
        chords += [.toggleSidebar, .fillScreen, .closeWindow, .increaseFontSize, .decreaseFontSize, .resetFontSize]
        chords += [.dismissToast, .dismissAllToasts]
        return chords.map(spec(for:))
    }

    private static func pane(
        _ title: String, _ shortcut: String, _ chord: KeyInterceptor.ReservedChord
    ) -> PaletteCommand {
        .init(title: title, shortcut: shortcut, category: Category.panes, chord: chord)
    }
    private static func tab(
        _ title: String, _ shortcut: String, _ chord: KeyInterceptor.ReservedChord
    ) -> PaletteCommand {
        .init(title: title, shortcut: shortcut, category: Category.tabs, chord: chord)
    }
    private static func drawer(
        _ title: String, _ shortcut: String, _ chord: KeyInterceptor.ReservedChord
    ) -> PaletteCommand {
        .init(title: title, shortcut: shortcut, category: Category.drawers, chord: chord)
    }
    private static func window(
        _ title: String, _ shortcut: String, _ chord: KeyInterceptor.ReservedChord
    ) -> PaletteCommand {
        .init(title: title, shortcut: shortcut, category: Category.window, chord: chord)
    }
    private static func tool(
        _ title: String, _ shortcut: String, _ chord: KeyInterceptor.ReservedChord
    ) -> PaletteCommand {
        .init(title: title, shortcut: shortcut, category: Category.tools, chord: chord)
    }
    private static func config(
        _ title: String, _ shortcut: String, _ chord: KeyInterceptor.ReservedChord
    ) -> PaletteCommand {
        .init(title: title, shortcut: shortcut, category: Category.config, chord: chord)
    }
    private static func help(
        _ title: String, _ shortcut: String, _ chord: KeyInterceptor.ReservedChord
    ) -> PaletteCommand {
        .init(title: title, shortcut: shortcut, category: Category.help, chord: chord)
    }
}
