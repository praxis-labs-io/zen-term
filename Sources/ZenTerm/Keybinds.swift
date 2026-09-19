import AppLog
import Foundation

extension KeyInterceptor.ReservedChord {
    var actionToken: String {
        switch self {
        case .splitVertical: return "split_vertical"
        case .splitHorizontal: return "split_horizontal"
        case .navLeft: return "nav_left"
        case .navRight: return "nav_right"
        case .navUp: return "nav_up"
        case .navDown: return "nav_down"
        case .prevPane: return "prev_pane"
        case .nextPane: return "next_pane"
        case .closePane: return "close_pane"
        case .closeTab: return "close_tab"
        case .closeWindow: return "close_window"
        case .newTab: return "new_tab"
        case .newWindow: return "new_window"
        case .selectTab(let n): return "select_tab_\(n)"
        case .prevTab: return "prev_tab"
        case .nextTab: return "next_tab"
        case .moveTabLeft: return "move_tab_left"
        case .moveTabRight: return "move_tab_right"
        case .renameTab: return "rename_tab"
        case .resizeLeft: return "resize_left"
        case .resizeRight: return "resize_right"
        case .resizeUp: return "resize_up"
        case .resizeDown: return "resize_down"
        case .toggleBottomDrawer: return "toggle_bottom_drawer"
        case .toggleRightDrawer: return "toggle_right_drawer"
        case .toggleZoom: return "toggle_focus_mode"
        case .fillScreen: return "fill_screen"
        case .toggleSidebar: return "toggle_sidebar"
        case .focusSidebar: return "focus_sidebar"
        case .toggleToolFloat(let id): return "toggle_float:\(id)"
        case .toggleRepoPicker: return "toggle_workspace_picker"
        case .createWorktree: return "create_worktree"
        case .removeWorktree: return "remove_worktree"
        case .toggleCommandPalette: return "toggle_command_palette"
        case .openSettings: return "open_settings"
        case .reloadConfig: return "reload_config"
        case .checkForUpdates: return "check_for_updates"
        case .reportIssue: return "report_issue"
        case .newTool: return "new_tool_float"
        case .increaseFontSize: return "increase_font_size"
        case .decreaseFontSize: return "decrease_font_size"
        case .resetFontSize: return "reset_font_size"
        case .toggleScrollMode: return "toggle_scroll_mode"
        case .toggleSearch: return "toggle_search"
        case .scrollToTop: return "scroll_to_top"
        case .scrollToBottom: return "scroll_to_bottom"
        case .scrollPageUp: return "scroll_page_up"
        case .scrollPageDown: return "scroll_page_down"
        case .findNext: return "search_next"
        case .findPrevious: return "search_previous"
        case .searchSelection: return "search_selection"
        case .clearScreen: return "clear_screen"
        case .selectAll: return "select_all"
        case .scrollToSelection: return "scroll_to_selection"
        case .writeScreenFile: return "write_screen_file"
        case .copyScreenFilePath: return "write_screen_file_copy"
        case .openScreenFile: return "write_screen_file_open"
        case .jumpToPreviousPrompt: return "jump_to_previous_prompt"
        case .jumpToNextPrompt: return "jump_to_next_prompt"
        case .pasteSelection: return "paste_selection"
        case .dismissToast: return "dismiss_toast"
        case .dismissAllToasts: return "dismiss_all_toasts"
        }
    }

    var shouldRepeat: Bool {
        switch self {
        case .navLeft, .navRight, .navUp, .navDown: return true
        case .resizeLeft, .resizeRight, .resizeUp, .resizeDown: return true
        case .increaseFontSize, .decreaseFontSize: return true
        case .scrollPageUp, .scrollPageDown: return true
        case .jumpToPreviousPrompt, .jumpToNextPrompt: return true
        case .splitVertical, .splitHorizontal, .closePane, .closeTab, .closeWindow,
            .newTab, .newWindow, .selectTab,
            .prevTab, .nextTab, .moveTabLeft, .moveTabRight, .renameTab,
            .toggleBottomDrawer, .toggleRightDrawer, .toggleZoom, .fillScreen, .toggleSidebar, .focusSidebar,
            .prevPane, .nextPane,
            .toggleToolFloat, .toggleRepoPicker, .createWorktree, .removeWorktree,
            .toggleCommandPalette,
            .openSettings,
            .reloadConfig, .checkForUpdates, .reportIssue, .newTool, .resetFontSize,
            .toggleScrollMode, .toggleSearch, .scrollToTop, .scrollToBottom,
            .findNext, .findPrevious, .searchSelection,
            .clearScreen, .selectAll, .scrollToSelection, .pasteSelection, .writeScreenFile,
            .copyScreenFilePath, .openScreenFile,
            .dismissToast, .dismissAllToasts:
            return false
        }
    }

    var isEditableInSettings: Bool {
        switch self {
        case .increaseFontSize, .decreaseFontSize, .resetFontSize: return false
        case .toggleToolFloat(let id): return ToolFloat.isBuiltIn(id)
        case .reloadConfig: return false
        case .checkForUpdates, .reportIssue: return false
        case .selectAll: return false
        case .splitVertical, .splitHorizontal, .closePane, .closeTab, .closeWindow, .toggleZoom,
            .toggleScrollMode, .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .scrollToSelection, .jumpToPreviousPrompt, .jumpToNextPrompt,
            .toggleSearch, .searchSelection, .findNext, .findPrevious,
            .clearScreen, .pasteSelection, .writeScreenFile,
            .copyScreenFilePath, .openScreenFile,
            .navLeft, .navRight, .navUp, .navDown, .prevPane, .nextPane,
            .resizeLeft, .resizeRight, .resizeUp, .resizeDown,
            .newTab, .newWindow, .prevTab, .nextTab, .selectTab,
            .moveTabLeft, .moveTabRight, .renameTab,
            .fillScreen, .toggleSidebar, .focusSidebar, .toggleBottomDrawer, .toggleRightDrawer,
            .toggleRepoPicker, .createWorktree, .removeWorktree, .toggleCommandPalette, .newTool,
            .openSettings,
            .dismissToast, .dismissAllToasts:
            return true
        }
    }

    init?(token: String) {
        switch token {
        case "split_vertical": self = .splitVertical
        case "split_horizontal": self = .splitHorizontal
        case "nav_left": self = .navLeft
        case "nav_right": self = .navRight
        case "nav_up": self = .navUp
        case "nav_down": self = .navDown
        case "prev_pane": self = .prevPane
        case "next_pane": self = .nextPane
        case "close_pane": self = .closePane
        case "close_tab": self = .closeTab
        case "close_window": self = .closeWindow
        case "new_tab": self = .newTab
        case "new_window": self = .newWindow
        case "prev_tab": self = .prevTab
        case "next_tab": self = .nextTab
        case "move_tab_left": self = .moveTabLeft
        case "move_tab_right": self = .moveTabRight
        case "rename_tab": self = .renameTab
        case "resize_left": self = .resizeLeft
        case "resize_right": self = .resizeRight
        case "resize_up": self = .resizeUp
        case "resize_down": self = .resizeDown
        case "toggle_bottom_drawer": self = .toggleBottomDrawer
        case "toggle_right_drawer": self = .toggleRightDrawer
        case "toggle_focus_mode": self = .toggleZoom
        case "toggle_zoom": self = .toggleZoom
        case "fill_screen": self = .fillScreen
        case "toggle_sidebar": self = .toggleSidebar
        case "focus_sidebar": self = .focusSidebar
        case "toggle_workspace_picker": self = .toggleRepoPicker
        case "toggle_repo_picker": self = .toggleRepoPicker
        case "create_worktree": self = .createWorktree
        case "remove_worktree": self = .removeWorktree
        case "toggle_command_palette": self = .toggleCommandPalette
        case "open_settings": self = .openSettings
        case "reload_config": self = .reloadConfig
        case "check_for_updates": self = .checkForUpdates
        case "report_issue": self = .reportIssue
        case "new_tool_float": self = .newTool
        case "increase_font_size": self = .increaseFontSize
        case "decrease_font_size": self = .decreaseFontSize
        case "reset_font_size": self = .resetFontSize
        case "toggle_scroll_mode": self = .toggleScrollMode
        case "toggle_search": self = .toggleSearch
        case "scroll_to_top": self = .scrollToTop
        case "scroll_to_bottom": self = .scrollToBottom
        case "scroll_page_up": self = .scrollPageUp
        case "scroll_page_down": self = .scrollPageDown
        case "search_next": self = .findNext
        case "search_previous": self = .findPrevious
        case "find_next": self = .findNext
        case "find_previous": self = .findPrevious
        case "search_selection": self = .searchSelection
        case "clear_screen": self = .clearScreen
        case "select_all": self = .selectAll
        case "scroll_to_selection": self = .scrollToSelection
        case "write_screen_file": self = .writeScreenFile
        case "write_screen_file_copy": self = .copyScreenFilePath
        case "write_screen_file_open": self = .openScreenFile
        case "jump_to_previous_prompt": self = .jumpToPreviousPrompt
        case "jump_to_next_prompt": self = .jumpToNextPrompt
        case "paste_selection": self = .pasteSelection
        case "dismiss_toast": self = .dismissToast
        case "dismiss_all_toasts": self = .dismissAllToasts
        case "start_search": self = .toggleSearch
        default:
            if let rest = token.dropPrefixIfPresent("select_tab_"), let n = Int(rest), (1...9).contains(n) {
                self = .selectTab(n)
            } else if let id = token.dropPrefixIfPresent("toggle_float:"), !id.isEmpty {
                self = .toggleToolFloat(id)
            } else {
                return nil
            }
        }
    }
}

/// One chord per action, except increase font size, which also needs ⌘⇧= for the US ⌘+ keypress.
enum KeymapDefaults {
    static func chords(of action: KeyInterceptor.ReservedChord) -> [Chord] {
        map.filter { $0.value == action }.map(\.key)
    }

    /// Avoids ⌘⌥D, ⌃⌘D, ⌘↑ and ⌘↓, which macOS claims before any app-level monitor runs.
    static let map: [Chord: KeyInterceptor.ReservedChord] = {
        var map: [Chord: KeyInterceptor.ReservedChord] = [:]

        map[Chord(command: true, key: "d")] = .splitVertical
        map[Chord(command: true, shift: true, key: "d")] = .splitHorizontal
        map[Chord(command: true, option: true, key: "←")] = .navLeft
        map[Chord(command: true, option: true, key: "→")] = .navRight
        map[Chord(command: true, option: true, key: "↑")] = .navUp
        map[Chord(command: true, option: true, key: "↓")] = .navDown
        map[Chord(command: true, control: true, key: "←")] = .resizeLeft
        map[Chord(command: true, control: true, key: "→")] = .resizeRight
        map[Chord(command: true, control: true, key: "↑")] = .resizeUp
        map[Chord(command: true, control: true, key: "↓")] = .resizeDown
        map[Chord(command: true, shift: true, key: "[")] = .prevPane
        map[Chord(command: true, shift: true, key: "]")] = .nextPane
        map[Chord(command: true, key: "w")] = .closePane
        map[Chord(command: true, control: true, key: "w")] = .closeTab
        map[Chord(command: true, shift: true, key: "w")] = .closeWindow
        map[Chord(command: true, shift: true, key: "s")] = .toggleScrollMode

        map[Chord(command: true, key: "[")] = .prevTab
        map[Chord(command: true, key: "]")] = .nextTab
        map[Chord(command: true, control: true, key: "[")] = .moveTabLeft
        map[Chord(command: true, control: true, key: "]")] = .moveTabRight
        map[Chord(command: true, key: "t")] = .newTab
        map[Chord(command: true, key: "n")] = .newWindow
        for n in 1...9 { map[Chord(command: true, key: "\(n)")] = .selectTab(n) }

        map[Chord(command: true, key: "⏎")] = .fillScreen
        map[Chord(command: true, shift: true, key: "⏎")] = .toggleZoom
        map[Chord(command: true, control: true, key: "s")] = .toggleSidebar

        map[Chord(command: true, key: "f")] = .toggleSearch

        map[Chord(command: true, shift: true, key: "p")] = .toggleCommandPalette
        map[Chord(command: true, key: "p")] = .toggleRepoPicker
        map[Chord(option: true, key: "⏎")] = .createWorktree
        map[Chord(command: true, shift: true, key: "⌫")] = .removeWorktree
        map[Chord(command: true, key: "\\")] = .toggleRightDrawer
        map[Chord(command: true, key: "b")] = .toggleBottomDrawer
        map[ToolFloat.scratch.toggle] = .toggleToolFloat(ToolFloat.scratch.id)
        map[Chord(command: true, key: ",")] = .openSettings
        map[Chord(command: true, shift: true, key: ",")] = .reloadConfig

        map[Chord(command: true, key: "=")] = .increaseFontSize
        map[Chord(command: true, shift: true, key: "=")] = .increaseFontSize
        map[Chord(command: true, key: "-")] = .decreaseFontSize
        map[Chord(command: true, key: "0")] = .resetFontSize

        map[Chord(command: true, key: "↖")] = .scrollToTop
        map[Chord(command: true, key: "↘")] = .scrollToBottom
        map[Chord(command: true, key: "⇞")] = .scrollPageUp
        map[Chord(command: true, key: "⇟")] = .scrollPageDown
        map[Chord(command: true, key: "e")] = .searchSelection

        map[Chord(command: true, key: "k")] = .clearScreen
        map[Chord(command: true, key: "j")] = .scrollToSelection
        map[Chord(command: true, shift: true, key: "j")] = .writeScreenFile
        map[Chord(command: true, shift: true, control: true, key: "j")] = .copyScreenFilePath
        map[Chord(command: true, shift: true, option: true, key: "j")] = .openScreenFile

        map[Chord(command: true, shift: true, key: "v")] = .pasteSelection
        map[Chord(command: true, shift: true, key: "↑")] = .jumpToPreviousPrompt
        map[Chord(command: true, shift: true, key: "↓")] = .jumpToNextPrompt

        map[Chord(command: true, shift: true, key: "n")] = .dismissToast
        map[Chord(command: true, shift: true, option: true, key: "n")] = .dismissAllToasts

        return map
    }()
}

/// Records deliberate unbinds, which a `[Chord: Action]` map cannot tell apart from defaults.
struct KeymapOverrides: Equatable {
    var binds: [Chord: KeyInterceptor.ReservedChord]
    var unbound: Set<KeyInterceptor.ReservedChord>

    init(binds: [Chord: KeyInterceptor.ReservedChord] = [:], unbound: Set<KeyInterceptor.ReservedChord> = []) {
        self.binds = binds
        self.unbound = unbound
    }

    mutating func bind(_ action: KeyInterceptor.ReservedChord, to chords: some Sequence<Chord>) {
        binds = binds.filter { $0.value != action }
        for chord in chords { binds[chord] = action }
        unbound.remove(action)
    }

    mutating func unbind(_ action: KeyInterceptor.ReservedChord) {
        binds = binds.filter { $0.value != action }
        unbound.insert(action)
    }

    mutating func clearOverride(_ action: KeyInterceptor.ReservedChord) {
        binds = binds.filter { $0.value != action }
        unbound.remove(action)
    }

    func chords(of action: KeyInterceptor.ReservedChord) -> Set<Chord> {
        Set(binds.filter { $0.value == action }.map(\.key))
    }

    init(config: GeneralConfig) {
        self.init(binds: Self.reserved(in: config.keymap), unbound: config.unboundActions)
    }

    init(defaults: [Chord: KeyInterceptor.ReservedChord]) {
        self.init(binds: Self.reserved(in: defaults))
    }

    /// Keeps user float toggles out: their chord lives on the `float =` line.
    private static func reserved(
        in map: [Chord: KeyInterceptor.ReservedChord]
    ) -> [Chord: KeyInterceptor.ReservedChord] {
        map.filter {
            if case .toggleToolFloat(let id) = $0.value { return ToolFloat.isBuiltIn(id) }
            return true
        }
    }
}

enum KeybindParser {
    enum Line: Equatable {
        case bind(Chord, KeyInterceptor.ReservedChord)
        case unbind(KeyInterceptor.ReservedChord)
    }

    /// `unbind` is ghostty's word; its trigger-first line shape stays unsupported.
    private static let unbindWords: Set<String> = ["none", "unbind"]

    /// An empty chord is unparseable rather than `none`, since a trailing `=` is usually a slip.
    static func parse(_ value: String) -> Line? {
        guard let equals = value.firstIndex(of: "=") else { return nil }
        let lhs = value[..<equals].trimmingCharacters(in: .whitespaces)
        let rhs = value[value.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard let action = KeyInterceptor.ReservedChord(token: lhs) else { return nil }
        if unbindWords.contains(rhs.lowercased()) { return .unbind(action) }
        guard let chord = Chord.parse(rhs) else { return nil }
        return .bind(chord, action)
    }
}

enum KeymapAssembler {
    struct Assembled {
        let map: [Chord: KeyInterceptor.ReservedChord]
        /// Excludes actions a displacement left chordless, so the writer never turns a conflict into an unbind.
        let unbound: Set<KeyInterceptor.ReservedChord>
        let diagnostics: [ConfigDiagnostic]
    }

    /// The closures are `@MainActor` because a plain function type erases `KeyboardLayout.canType`'s isolation.
    @MainActor
    static func assemble(
        floats: [ToolFloat], keybinds: [KeybindParser.Line],
        canType: @MainActor (Chord) -> Bool = KeyboardLayout.canType,
        protected: @MainActor () -> Set<Chord> = MenuShortcuts.protected,
        menuOwner: @MainActor (Chord) -> String? = MenuShortcuts.owner
    ) -> Assembled {
        var map = KeymapDefaults.map
        let floatIDs = Set(floats.map(\.id)).union(ToolFloat.builtInIDs)
        var displacements: [Displacement] = []
        let menuChords = protected()

        var requestedUnbinds: [KeyInterceptor.ReservedChord] = []
        var binds: [(Chord, KeyInterceptor.ReservedChord)] = []
        for line in keybinds {
            switch line {
            case .bind(let chord, let action): binds.append((chord, action))
            case .unbind(let action):
                if case .toggleToolFloat(let id) = action, !ToolFloat.isBuiltIn(id) {
                    Log.warning(
                        "GeneralConfig: keybind toggle_float:\(id)=none can't unbind a float. Its "
                            + "chord is the `key:` on its float line: ignored", category: .keybinds)
                    continue
                }
                requestedUnbinds.append(action)
            }
        }

        var typeable: [(Chord, KeyInterceptor.ReservedChord)] = []
        var untypeable: [(Chord, KeyInterceptor.ReservedChord)] = []
        var menuOwned: [(Chord, KeyInterceptor.ReservedChord)] = []
        for bind in binds {
            if menuChords.contains(bind.0) {
                menuOwned.append(bind)
            } else if canType(bind.0) {
                typeable.append(bind)
            } else {
                untypeable.append(bind)
            }
        }
        for (chord, action) in untypeable {
            Log.warning(
                "GeneralConfig: keybind \(action.actionToken)=\(chord.configToken) can't be typed: ignored",
                category: .keybinds)
        }
        for (chord, action) in menuOwned {
            Log.warning(
                "GeneralConfig: keybind \(action.actionToken)=\(chord.configToken) is a menu shortcut: ignored",
                category: .keybinds)
        }

        let reboundActions = typeable.map(\.1)
        map = map.filter { entry in
            !reboundActions.contains(entry.value) && !requestedUnbinds.contains(entry.value)
        }

        func set(_ chord: Chord, _ action: KeyInterceptor.ReservedChord) {
            if let existing = map[chord], existing != action {
                Log.info(
                    "GeneralConfig: chord \(chord.displayGlyph) rebound from \(existing.actionToken) "
                        + "to \(action.actionToken)", category: .keybinds)
                displacements.append(Displacement(chord: chord, loser: existing))
            }
            map[chord] = action
        }

        var menuOwnedFloats: [ToolFloat] = []
        for float in floats where !ToolFloat.isBuiltIn(float.id) {
            if menuChords.contains(float.toggle) {
                menuOwnedFloats.append(float)
                Log.warning(
                    "GeneralConfig: float \(float.id) key \(float.toggle.configToken) is a menu shortcut: ignored",
                    category: .keybinds)
                continue
            }
            set(float.toggle, .toggleToolFloat(float.id))
        }
        for (chord, action) in typeable {
            if case .toggleToolFloat(let id) = action, !floatIDs.contains(id) {
                Log.warning(
                    "GeneralConfig: keybind action toggle_float:\(id) names no configured float: ignored",
                    category: .keybinds)
                continue
            }
            set(chord, action)
        }
        return Assembled(
            map: map,
            unbound: Set(requestedUnbinds.filter { !map.values.contains($0) }),
            diagnostics: diagnostics(for: displacements, in: map) + untypeableDiagnostics(untypeable)
                + menuDiagnostics(menuOwned, floats: menuOwnedFloats, owner: menuOwner)
        )
    }

    @MainActor
    private static func menuDiagnostics(
        _ binds: [(Chord, KeyInterceptor.ReservedChord)], floats: [ToolFloat],
        owner: @MainActor (Chord) -> String?
    ) -> [ConfigDiagnostic] {
        binds.map { chord, action in
            ConfigDiagnostic(
                scope: .keybind(action),
                problem: .menuBind(chord, menuItem: owner(chord)))
        }
            + floats.map { float in
                ConfigDiagnostic(
                    scope: .toolFloatField(id: float.id, label: float.title),
                    problem: .floatMenuKey(float.toggle, menuItem: owner(float.toggle)))
            }
    }

    private static func untypeableDiagnostics(
        _ untypeable: [(Chord, KeyInterceptor.ReservedChord)]
    ) -> [ConfigDiagnostic] {
        untypeable.map { chord, action in
            ConfigDiagnostic(scope: .keybind(action), problem: .unusableBind(chord))
        }
    }

    /// Omits the winner: a later write can retake the chord, so it's read from the finished map.
    private struct Displacement {
        let chord: Chord
        let loser: KeyInterceptor.ReservedChord
    }

    private static func diagnostics(
        for displacements: [Displacement], in map: [Chord: KeyInterceptor.ReservedChord]
    ) -> [ConfigDiagnostic] {
        var seen: [KeyInterceptor.ReservedChord] = []
        return displacements.compactMap { displacement in
            guard !map.values.contains(displacement.loser), !seen.contains(displacement.loser),
                let winner = map[displacement.chord]
            else { return nil }
            seen.append(displacement.loser)
            return ConfigDiagnostic(
                scope: .keybind(displacement.loser),
                problem: .chordTaken(displacement.chord, by: winner))
        }
    }
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
