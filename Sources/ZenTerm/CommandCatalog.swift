import Foundation

/// One palette entry: a display title, its shortcut glyph string, the group it belongs to,
/// and the chord it runs.
struct PaletteCommand {
    let title: String
    let shortcut: String
    let category: String
    let chord: KeyInterceptor.ReservedChord
}

/// The command palette's action list, derived from `KeyInterceptor.ReservedChord`. The
/// `spec(for:)` switch is exhaustive, so the palette can't drift out of sync with the
/// keybindings: adding a chord fails to compile until it has a title here.
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

    /// Title, display shortcut, and group for a chord. Exhaustive over `ReservedChord`. The
    /// glyph is read from the live keymap (`displayGlyph`), so it tracks user rebinds instead
    /// of showing a stale default.
    static func spec(for chord: KeyInterceptor.ReservedChord) -> PaletteCommand {
        let glyph = displayGlyph(for: chord)
        switch chord {
        case .splitHorizontal: return pane("Split Horizontally", glyph, chord)
        case .splitVertical: return pane("Split Vertically", glyph, chord)
        case .navLeft: return pane("Focus Pane Left", glyph, chord)
        case .navDown: return pane("Focus Pane Down", glyph, chord)
        case .navUp: return pane("Focus Pane Up", glyph, chord)
        case .navRight: return pane("Focus Pane Right", glyph, chord)
        case .resizeLeft: return pane("Resize Pane Left", glyph, chord)
        case .resizeDown: return pane("Resize Pane Down", glyph, chord)
        case .resizeUp: return pane("Resize Pane Up", glyph, chord)
        case .resizeRight: return pane("Resize Pane Right", glyph, chord)
        case .toggleZoom: return pane("Focus Mode", glyph, chord)
        case .fillScreen: return window("Fill Screen", glyph, chord)
        case .closePane: return pane("Close Pane", glyph, chord)
        case .newTab: return tab("New Tab", glyph, chord)
        case .prevTab: return tab("Previous Tab", glyph, chord)
        case .nextTab: return tab("Next Tab", glyph, chord)
        case .selectTab(let n): return tab("Select Tab \(n)", glyph, chord)
        case .toggleBottomDrawer: return drawer("Toggle Bottom Drawer", glyph, chord)
        case .toggleRightDrawer: return drawer("Toggle Right Drawer", glyph, chord)
        case .toggleToolFloat(let id): return tool(ToolFloatCatalog.byID(id)?.title ?? id, glyph, chord)
        case .toggleRepoPicker: return tool("Open Workspace Picker", glyph, chord)
        case .openSettings: return config("Settings…", glyph, chord)
        case .reloadConfig: return config("Reload Config", glyph, chord)
        case .checkForUpdates: return config("Check for Updates", glyph, chord)
        case .reportIssue: return help("Report an Issue…", glyph, chord)
        case .openDiffViewer: return tool("Diff Viewer", glyph, chord)
        // Present for exhaustiveness; all are omitted from `commands(tabCount:)`.
        case .newWindow: return tab("New Window", glyph, chord)
        case .toggleCommandPalette: return tool("Command Palette", glyph, chord)
        }
    }

    /// The glyph currently bound to an action, from the live keymap — empty if unbound.
    private static func displayGlyph(for chord: KeyInterceptor.ReservedChord) -> String {
        Chord.displayed(chord, in: GeneralConfig.current.keymap)?.displayGlyph ?? ""
    }

    /// The ordered commands shown for a window with `tabCount` tabs, grouped by category
    /// (Tools → Config → Drawers → Tabs → Panes → Window). Tools leads with the workspace picker,
    /// then the configured tool floats; Config holds Settings, Reload Config, Check for Updates;
    /// Window holds Fill
    /// Screen. `.selectTab` expands to one entry per open tab (capped at the bound ⌘1–⌘9). The
    /// command palette itself and New Window aren't shown.
    static func commands(tabCount: Int) -> [PaletteCommand] {
        var chords: [KeyInterceptor.ReservedChord] = [.toggleRepoPicker, .openDiffViewer]
        chords += ToolFloatCatalog.all.map { .toggleToolFloat($0.id) }
        chords += [.openSettings, .reloadConfig, .checkForUpdates, .reportIssue]
        chords += [
            .toggleBottomDrawer, .toggleRightDrawer,
            .newTab, .prevTab, .nextTab,
        ]
        if tabCount > 0 {
            chords += (1...min(tabCount, 9)).map { .selectTab($0) }
        }
        chords += [
            .splitHorizontal, .splitVertical,
            .navLeft, .navDown, .navUp, .navRight,
            .resizeLeft, .resizeDown, .resizeUp, .resizeRight,
            .toggleZoom, .closePane,
        ]
        chords += [.fillScreen]
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
