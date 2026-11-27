import Foundation

struct PaletteCommand {
    let title: String
    let shortcut: String
    let category: CommandCategory
    let chord: KeyInterceptor.ReservedChord
    var ownIcon: ProcessIcon?

    var icon: ProcessIcon { ownIcon ?? category.icon }
}

enum CommandCatalog {
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
        case .focusSidebar: return window("Focus Sidebar", glyph, chord)
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
        case .toggleBottomDrawer: return tab("Toggle Bottom Drawer", glyph, chord)
        case .toggleRightDrawer: return tab("Toggle Right Drawer", glyph, chord)
        case .toggleToolFloat(let id):
            let float = ToolFloatCatalog.byID(id)
            return .init(
                title: float?.title ?? id, shortcut: glyph, category: .tools, chord: chord,
                ownIcon: float.flatMap(ProcessIcon.toolFloat))
        case .toggleRepoPicker: return workspace("Open Workspace Picker", glyph, chord)
        case .newWorkspace: return workspace("New Workspace", glyph, chord)
        case .openSettings: return app("Settings…", glyph, chord)
        case .reloadConfig: return app("Reload Config", glyph, chord)
        case .checkForUpdates: return app("Check for Updates", glyph, chord)
        case .reportIssue: return app("Report an Issue…", glyph, chord)
        case .newTool: return tool("New Tool Float…", glyph, chord)
        case .increaseFontSize: return app("Increase Font Size", glyph, chord)
        case .decreaseFontSize: return app("Decrease Font Size", glyph, chord)
        case .resetFontSize: return app("Reset Font Size", glyph, chord)
        case .toggleScrollMode: return terminal("Scroll Mode", glyph, chord, icon: .scrollMode)
        case .toggleSearch: return terminal("Find in Scrollback", glyph, chord, icon: .find)
        case .scrollToTop: return terminal("Scroll to Top", glyph, chord)
        case .scrollToBottom: return terminal("Scroll to Bottom", glyph, chord)
        case .scrollPageUp: return terminal("Scroll Page Up", glyph, chord)
        case .scrollPageDown: return terminal("Scroll Page Down", glyph, chord)
        case .searchSelection: return terminal("Find Selection", glyph, chord)
        case .clearScreen: return terminal("Clear Screen", glyph, chord)
        case .scrollToSelection: return terminal("Scroll to Selection", glyph, chord)
        case .jumpToPreviousPrompt: return terminal("Jump to Previous Prompt", glyph, chord)
        case .jumpToNextPrompt: return terminal("Jump to Next Prompt", glyph, chord)
        case .pasteSelection: return terminal("Paste Selection", glyph, chord)
        case .writeScreenFile: return terminal("Write Screen to File", glyph, chord)
        case .copyScreenFilePath: return terminal("Write Screen to File, Copy Path", glyph, chord)
        case .openScreenFile: return terminal("Write Screen to File and Open", glyph, chord)
        case .dismissToast: return app("Dismiss Notice", glyph, chord)
        case .dismissAllToasts: return app("Dismiss All Notices", glyph, chord)
        case .newWindow: return window("New Window", glyph, chord)
        case .selectAll: return terminal("Select All", glyph, chord)
        case .toggleCommandPalette: return tool("Command Palette", glyph, chord)
        case .findNext: return terminal("Find Next", glyph, chord)
        case .createWorktree: return workspace("New Worktree…", glyph, chord)
        case .removeWorktree: return workspace("Remove Worktree…", glyph, chord)
        case .findPrevious: return terminal("Find Previous", glyph, chord)
        case .selectWorkspace(let n): return workspace("Select Workspace \(n)", glyph, chord)
        case .prevWorkspace: return workspace("Previous Workspace", glyph, chord)
        case .nextWorkspace: return workspace("Next Workspace", glyph, chord)
        case .closeWorkspace: return workspace("Close Workspace", glyph, chord)
        case .renameWorkspace: return workspace("Rename Workspace…", glyph, chord)
        case .nextWaitingAgent: return workspace("Jump to Waiting Agent", glyph, chord)
        case .toggleAgentPicker: return workspace("Open Agent Picker", glyph, chord)
        }
    }

    private static func displayGlyph(for chord: KeyInterceptor.ReservedChord) -> String {
        Chord.displayed(chord, in: GeneralConfig.current.keymap)?.displayGlyph ?? ""
    }

    static func commands(tabCount: Int, workspaceCount: Int, onHost: Bool = false) -> [PaletteCommand] {
        var chords: [KeyInterceptor.ReservedChord] = [
            .toggleRepoPicker, .newWorkspace, .prevWorkspace, .nextWorkspace,
        ]
        if workspaceCount > 0 {
            chords += (1...min(workspaceCount, 9)).map { .selectWorkspace($0) }
        }
        if !onHost { chords += [.renameWorkspace] }
        if !onHost || tabCount > 0 { chords += [.closeWorkspace] }
        chords += [.nextWaitingAgent, .toggleAgentPicker]
        chords += [
            .newTab, .prevTab, .nextTab, .moveTabLeft, .moveTabRight, .renameTab, .closeTab,
        ]
        if tabCount > 0 {
            chords += (1...min(tabCount, 9)).map { .selectTab($0) }
        }
        chords += [.toggleBottomDrawer, .toggleRightDrawer]
        chords += [
            .splitHorizontal, .splitVertical,
            .navLeft, .navDown, .navUp, .navRight, .prevPane, .nextPane,
            .resizeLeft, .resizeDown, .resizeUp, .resizeRight,
            .toggleZoom, .closePane,
        ]
        chords += [
            .toggleScrollMode, .toggleSearch, .searchSelection,
            .scrollPageUp, .scrollPageDown, .scrollToTop, .scrollToBottom,
            .jumpToPreviousPrompt, .jumpToNextPrompt, .scrollToSelection,
            .clearScreen, .pasteSelection, .writeScreenFile,
            .copyScreenFilePath, .openScreenFile,
        ]
        chords += [.closeWindow, .fillScreen, .toggleSidebar, .focusSidebar]
        chords += ToolFloatCatalog.all.map { .toggleToolFloat($0.id) }
        chords += [.newTool]
        chords += [
            .openSettings, .reloadConfig, .checkForUpdates,
            .increaseFontSize, .decreaseFontSize, .resetFontSize,
            .dismissToast, .dismissAllToasts, .reportIssue,
        ]
        let onConnect = onHost && tabCount == 0
        return chords.map {
            switch $0 {
            case .closeWorkspace where onHost: disconnect
            case .searchSelection where onConnect: editHost
            default: spec(for: $0)
            }
        }
    }

    // A host's Connect screen has no terminal to find in, so the chord edits the host instead.
    private static var editHost: PaletteCommand {
        workspace("Edit Host…", displayGlyph(for: .searchSelection), .searchSelection)
    }

    private static var disconnect: PaletteCommand {
        workspace("Disconnect", displayGlyph(for: .closeWorkspace), .closeWorkspace)
    }

    private static func pane(
        _ title: String, _ shortcut: String, _ chord: KeyInterceptor.ReservedChord
    ) -> PaletteCommand {
        .init(title: title, shortcut: shortcut, category: .panes, chord: chord)
    }
    private static func terminal(
        _ title: String, _ shortcut: String, _ chord: KeyInterceptor.ReservedChord, icon: ProcessIcon? = nil
    ) -> PaletteCommand {
        .init(title: title, shortcut: shortcut, category: .terminal, chord: chord, ownIcon: icon)
    }
    private static func tab(
        _ title: String, _ shortcut: String, _ chord: KeyInterceptor.ReservedChord
    ) -> PaletteCommand {
        .init(title: title, shortcut: shortcut, category: .tabs, chord: chord)
    }
    private static func window(
        _ title: String, _ shortcut: String, _ chord: KeyInterceptor.ReservedChord
    ) -> PaletteCommand {
        .init(title: title, shortcut: shortcut, category: .window, chord: chord)
    }
    private static func tool(
        _ title: String, _ shortcut: String, _ chord: KeyInterceptor.ReservedChord
    ) -> PaletteCommand {
        .init(title: title, shortcut: shortcut, category: .tools, chord: chord)
    }
    private static func app(
        _ title: String, _ shortcut: String, _ chord: KeyInterceptor.ReservedChord
    ) -> PaletteCommand {
        .init(title: title, shortcut: shortcut, category: .app, chord: chord)
    }
    private static func workspace(
        _ title: String, _ shortcut: String, _ chord: KeyInterceptor.ReservedChord
    ) -> PaletteCommand {
        .init(title: title, shortcut: shortcut, category: .workspaces, chord: chord)
    }
}
