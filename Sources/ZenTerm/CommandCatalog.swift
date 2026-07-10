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
        static let tools = "Tools"
    }

    /// Title, display shortcut, and group for a chord. Exhaustive over `ReservedChord`.
    static func spec(for chord: KeyInterceptor.ReservedChord) -> PaletteCommand {
        switch chord {
        case .splitHorizontal: return pane("Split Horizontally", "⌘-", chord)
        case .splitVertical: return pane("Split Vertically", "⌘|", chord)
        case .navLeft: return pane("Focus Pane Left", "⌘H", chord)
        case .navDown: return pane("Focus Pane Down", "⌘J", chord)
        case .navUp: return pane("Focus Pane Up", "⌘K", chord)
        case .navRight: return pane("Focus Pane Right", "⌘L", chord)
        case .resizeLeft: return pane("Resize Pane Left", "⌘⇧H", chord)
        case .resizeDown: return pane("Resize Pane Down", "⌘⇧J", chord)
        case .resizeUp: return pane("Resize Pane Up", "⌘⇧K", chord)
        case .resizeRight: return pane("Resize Pane Right", "⌘⇧L", chord)
        case .toggleZoom: return pane("Toggle Zoom", "⌘F", chord)
        case .closePane: return pane("Close Pane", "⌘W", chord)
        case .newTab: return tab("New Tab", "⌘T", chord)
        case .prevTab: return tab("Previous Tab", "⌘[", chord)
        case .nextTab: return tab("Next Tab", "⌘]", chord)
        case .selectTab(let n): return tab("Select Tab \(n)", "⌘\(n)", chord)
        case .toggleBottomDrawer: return drawer("Toggle Bottom Drawer", "⌘B", chord)
        case .toggleRightDrawer: return drawer("Toggle Right Drawer", "⌘\\", chord)
        case .toggleLazygit: return tool("Open Lazygit", "⌘G", chord)
        case .toggleToolFloat(let id):
            let f = ToolFloatCatalog.byID(id)
            return tool(f?.title ?? id, f?.shortcut ?? "", chord)
        case .toggleRepoPicker: return tool("Open Project Picker", "⌘⇧P", chord)
        case .toggleWebPanePicker: return tool("Open Web Pane", "⌘⇧B", chord)
        // Present for exhaustiveness; both are omitted from `commands(tabCount:)`.
        case .newWindow: return tab("New Window", "⌘N", chord)
        case .toggleCommandPalette: return tool("Command Palette", "⌘P", chord)
        }
    }

    /// The ordered commands shown for a window with `tabCount` tabs, grouped by category
    /// (Tools → Drawers → Tabs → Panes). `.selectTab` expands to one entry per open tab
    /// (capped at the bound ⌘1–⌘9). The command palette itself and New Window aren't shown.
    static func commands(tabCount: Int) -> [PaletteCommand] {
        var chords: [KeyInterceptor.ReservedChord] = [
            .toggleRepoPicker, .toggleWebPanePicker, .toggleLazygit,
        ]
        chords += ToolFloatCatalog.all.map { .toggleToolFloat($0.id) }
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
    private static func tool(
        _ title: String, _ shortcut: String, _ chord: KeyInterceptor.ReservedChord
    ) -> PaletteCommand {
        .init(title: title, shortcut: shortcut, category: Category.tools, chord: chord)
    }
}
