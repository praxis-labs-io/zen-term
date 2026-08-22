import AppLog
import Foundation

extension KeyInterceptor.ReservedChord {
    /// The canonical snake_case action name used in the config file (`keybind = … = <token>`).
    /// A `switch` so adding a `ReservedChord` case forces a token here at compile time.
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
        case .newTab: return "new_tab"
        case .newWindow: return "new_window"
        case .selectTab(let n): return "select_tab_\(n)"
        case .prevTab: return "prev_tab"
        case .nextTab: return "next_tab"
        case .resizeLeft: return "resize_left"
        case .resizeRight: return "resize_right"
        case .resizeUp: return "resize_up"
        case .resizeDown: return "resize_down"
        case .toggleBottomDrawer: return "toggle_bottom_drawer"
        case .toggleRightDrawer: return "toggle_right_drawer"
        case .toggleZoom: return "toggle_focus_mode"
        case .fillScreen: return "fill_screen"
        case .toggleToolFloat(let id): return "toggle_float:\(id)"
        case .toggleRepoPicker: return "toggle_workspace_picker"
        case .toggleCommandPalette: return "toggle_command_palette"
        case .openSettings: return "open_settings"
        case .reloadConfig: return "reload_config"
        case .checkForUpdates: return "check_for_updates"
        case .reportIssue: return "report_issue"
        case .newTool: return "new_tool_float"
        // ghostty's own spelling for these three, so a keybind line pasted from a ghostty config
        // resolves rather than being dropped as unknown.
        case .increaseFontSize: return "increase_font_size"
        case .decreaseFontSize: return "decrease_font_size"
        case .resetFontSize: return "reset_font_size"
        case .toggleScrollMode: return "toggle_scroll_mode"
        case .toggleSearch: return "toggle_search"
        // ghostty's own spelling again, for the same reason as the font sizes.
        case .scrollToTop: return "scroll_to_top"
        case .scrollToBottom: return "scroll_to_bottom"
        case .scrollPageUp: return "scroll_page_up"
        case .scrollPageDown: return "scroll_page_down"
        // Ours: ghostty spells these `navigate_search:next` and `navigate_search:previous`, and no
        // token here carries an argument.
        case .findNext: return "search_next"
        case .findPrevious: return "search_previous"
        case .searchSelection: return "search_selection"
        // ghostty's own spelling for the four it has one for.
        case .clearScreen: return "clear_screen"
        case .selectAll: return "select_all"
        case .scrollToSelection: return "scroll_to_selection"
        case .writeScreenFile: return "write_screen_file"
        case .copyScreenFilePath: return "write_screen_file_copy"
        case .openScreenFile: return "write_screen_file_open"
        // Ours: ghostty spells the prompt jumps `jump_to_prompt:-1` and `jump_to_prompt:1`, and no
        // token here carries an argument. `paste_from_selection` is its name for reading the X11
        // selection clipboard, which macOS has none of, so a separate word for a separate thing.
        case .jumpToPreviousPrompt: return "jump_to_previous_prompt"
        case .jumpToNextPrompt: return "jump_to_next_prompt"
        case .pasteSelection: return "paste_selection"
        case .dismissToast: return "dismiss_toast"
        case .dismissAllToasts: return "dismiss_all_toasts"
        }
    }

    /// Whether holding the chord down should fire the action again at the key-repeat rate.
    ///
    /// Only actions whose effect accumulates and whose hold runs out of room on its own: nav stops
    /// at the edge pane, resize at the minimum, a page scroll at the end of the buffer. Everything
    /// else is discrete, and a held ⌘N spawning windows at 30 a second is the bug this answers.
    /// Tab cycling and search stepping wrap, so a hold never lands anywhere aimed.
    ///
    /// A `switch` so a new `ReservedChord` case has to answer.
    var shouldRepeat: Bool {
        switch self {
        case .navLeft, .navRight, .navUp, .navDown: return true
        case .resizeLeft, .resizeRight, .resizeUp, .resizeDown: return true
        case .increaseFontSize, .decreaseFontSize: return true
        case .scrollPageUp, .scrollPageDown: return true
        case .jumpToPreviousPrompt, .jumpToNextPrompt: return true
        case .splitVertical, .splitHorizontal, .closePane, .newTab, .newWindow, .selectTab,
            .prevTab, .nextTab, .toggleBottomDrawer, .toggleRightDrawer, .toggleZoom, .fillScreen,
            .prevPane, .nextPane,
            .toggleToolFloat, .toggleRepoPicker, .toggleCommandPalette, .openSettings,
            .reloadConfig, .checkForUpdates, .reportIssue, .newTool, .resetFontSize,
            .toggleScrollMode, .toggleSearch, .scrollToTop, .scrollToBottom,
            .findNext, .findPrevious, .searchSelection,
            .clearScreen, .selectAll, .scrollToSelection, .pasteSelection, .writeScreenFile,
            .copyScreenFilePath, .openScreenFile,
            // Discrete on purpose, though the effect does accumulate: at the key-repeat rate a hold
            // would clear a notice you hadn't read yet. Presses walk the stack; `dismissAllToasts`
            // is the one for clearing it in a keystroke.
            .dismissToast, .dismissAllToasts:
            return false
        }
    }

    /// Whether the Shortcuts settings card offers a row for this action.
    ///
    /// A `switch` because the card's group list is hand-ordered, so an action missing from it is
    /// invisible rather than broken: seven shipped with no row and nothing went red.
    /// `SettingsKeybindGroupsTests` measures the list against this.
    ///
    /// The ones that say no are file-only: the font sizes belong to the Terminal card's control,
    /// Reload Config is what you press while editing the file, a user float's chord lives on its
    /// own `float =` line, and the rest are errands the menu bar already carries. Shipping unbound
    /// is not a reason.
    ///
    /// The built-in Scratch float is the exception, and has to be: it has no `float =` line and no
    /// Tools row, so the Shortcuts card is the only place its chord can be edited, and the only
    /// place a conflict against it can be reported.
    var isEditableInSettings: Bool {
        switch self {
        case .increaseFontSize, .decreaseFontSize, .resetFontSize: return false
        case .toggleToolFloat(let id): return ToolFloat.isBuiltIn(id)
        case .reloadConfig: return false
        case .checkForUpdates, .reportIssue: return false
        // Edit > Select All holds ⌘A, so the row would be an editor for a chord it has to refuse.
        case .selectAll: return false
        case .splitVertical, .splitHorizontal, .closePane, .toggleZoom,
            .toggleScrollMode, .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown,
            .scrollToSelection, .jumpToPreviousPrompt, .jumpToNextPrompt,
            .toggleSearch, .searchSelection, .findNext, .findPrevious,
            .clearScreen, .pasteSelection, .writeScreenFile,
            .copyScreenFilePath, .openScreenFile,
            .navLeft, .navRight, .navUp, .navDown, .prevPane, .nextPane,
            .resizeLeft, .resizeRight, .resizeUp, .resizeDown,
            .newTab, .newWindow, .prevTab, .nextTab, .selectTab,
            .fillScreen, .toggleBottomDrawer, .toggleRightDrawer,
            .toggleRepoPicker, .toggleCommandPalette, .newTool, .openSettings,
            .dismissToast, .dismissAllToasts:
            return true
        }
    }

    /// Inverse of `actionToken`: parse a config action name back to a chord, or `nil` for an
    /// unknown token (caller warns + skips). The two parameterized families resolve by prefix.
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
        case "new_tab": self = .newTab
        case "new_window": self = .newWindow
        case "prev_tab": self = .prevTab
        case "next_tab": self = .nextTab
        case "resize_left": self = .resizeLeft
        case "resize_right": self = .resizeRight
        case "resize_up": self = .resizeUp
        case "resize_down": self = .resizeDown
        case "toggle_bottom_drawer": self = .toggleBottomDrawer
        case "toggle_right_drawer": self = .toggleRightDrawer
        case "toggle_focus_mode": self = .toggleZoom
        // Back-compat: the action was renamed from zoom to Focus Mode; an existing
        // config with the old token still resolves rather than silently dropping the binding.
        case "toggle_zoom": self = .toggleZoom
        case "fill_screen": self = .fillScreen
        case "toggle_workspace_picker": self = .toggleRepoPicker
        // Back-compat: the config token is `toggle_workspace_picker` — the product calls it
        // a workspace everywhere, and `repo` was the one token whose product name moved on. The old
        // `toggle_repo_picker` still resolves so an existing binding keeps working.
        case "toggle_repo_picker": self = .toggleRepoPicker
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
        // Back-compat: the config file speaks `search` throughout, so the two stepping actions
        // moved to match `toggle_search`. The `find_` tokens still resolve.
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
        // ghostty's own spelling, so a config carried over from it binds our find bar rather than
        // failing to parse.
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

/// The built-in chord → action map, which the user's `keybind` lines and float `key:` chords
/// overlay. A user float's chord comes from its own `key:` field. Scratch, the one built-in float,
/// has no such field, so its chord is a default here like any other action's.
///
/// These are ghostty's chords wherever the two would disagree, so a hand arriving from it lands
/// right.
///
/// **One chord per action.** A second spelling costs a Shortcuts row that has to pick one to
/// advertise, a reference-config line nobody asked for, and a rebind that has to free both.
/// Increase font size is the only exception, and a layout artifact rather than a second chord.
/// `KeymapAssemblyTests` holds the rule.
enum KeymapDefaults {
    /// The chords `action` ships with. One accessor rather than the same `filter`/`keys` walk written
    /// out at each call site: a row and the writer disagreeing about what an action's default *is*
    /// is the shape of every silent bug in this area.
    static func chords(of action: KeyInterceptor.ReservedChord) -> [Chord] {
        map.filter { $0.value == action }.map(\.key)
    }

    static let map: [Chord: KeyInterceptor.ReservedChord] = {
        var map: [Chord: KeyInterceptor.ReservedChord] = [:]

        // Panes, on ghostty's chords throughout: ⌘D and ⌘⇧D split, ⌘⌥arrows focus one, ⌘⌃arrows
        // resize one. ⌘D is the most-pressed chord in a ghostty split workflow after ⌘T, so landing
        // somewhere else is a hard stop rather than a surprise, and the diff viewer gives it up.
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
        // Stepping through the panels in order, wrapping. ghostty spells this ⌘[ / ⌘],
        // which ZenTerm spends on tabs, so it takes the shifted pair. That is ghostty's tab cycling,
        // so the bracket family is inverted here on both rows, deliberately and in one direction:
        // tabs unshifted, panes shifted.
        map[Chord(command: true, shift: true, key: "[")] = .prevPane
        map[Chord(command: true, shift: true, key: "]")] = .nextPane
        map[Chord(command: true, key: "w")] = .closePane
        map[Chord(command: true, shift: true, key: "s")] = .toggleScrollMode

        // Tabs and the window. ⌘[ and ⌘] are tabs and are the only ones: the Safari convention,
        // and ghostty is the outlier here. `Chord` parses `tab`, so a config binding ghostty's ⌃⇥
        // resolves.
        map[Chord(command: true, key: "[")] = .prevTab
        map[Chord(command: true, key: "]")] = .nextTab
        map[Chord(command: true, key: "t")] = .newTab
        map[Chord(command: true, key: "n")] = .newWindow
        for n in 1...9 { map[Chord(command: true, key: "\(n)")] = .selectTab(n) }

        // Fill Screen and Focus Mode, on ghostty's chords for the same two things
        // (`toggle_fullscreen` and `toggle_split_zoom`), which is what leaves ⌘F for Find.
        //
        // ghostty spells fullscreen ⌃⌘F as well and that one stays unbound: it is macOS's native
        // fullscreen chord, and this is a maximize, so answering it would promise a space switch.
        map[Chord(command: true, key: "⏎")] = .fillScreen
        map[Chord(command: true, shift: true, key: "⏎")] = .toggleZoom

        // Finding, on ⌘F alone. ⌘? folds to "/" carrying shift, so ⌘/ is a separate chord and this
        // does not claim it either way.
        map[Chord(command: true, key: "f")] = .toggleSearch

        // ⌘⇧P is ghostty's command palette and VS Code's, so the workspace picker takes ⌘P.
        //
        // The diff viewer wants a D and cannot have one: macOS claims ⌘⌥D and ⌃⌘D before any
        // app-level monitor runs, so a chord bound there is dead and every test of it passes.
        map[Chord(command: true, shift: true, key: "p")] = .toggleCommandPalette
        map[Chord(command: true, key: "p")] = .toggleRepoPicker
        map[Chord(command: true, key: "\\")] = .toggleRightDrawer
        map[Chord(command: true, key: "b")] = .toggleBottomDrawer
        // The one built-in float, beside the two drawers it behaves like. Read off the spec so the
        // default and the float cannot drift apart.
        map[ToolFloat.scratch.toggle] = .toggleToolFloat(ToolFloat.scratch.id)
        map[Chord(command: true, key: ",")] = .openSettings
        map[Chord(command: true, shift: true, key: ",")] = .reloadConfig

        // Font size, matching what libghostty bound before the chrome took these over.
        //
        // Increase needs BOTH entries: "⌘+" on a US layout is physically ⌘⇧=, which `Chord` folds
        // back onto "=", so binding ⌘= alone lets the keypress most people make fall through to
        // libghostty, which still has it bound per surface.
        map[Chord(command: true, key: "=")] = .increaseFontSize
        map[Chord(command: true, shift: true, key: "=")] = .increaseFontSize
        map[Chord(command: true, key: "-")] = .decreaseFontSize
        map[Chord(command: true, key: "0")] = .resetFontSize

        // Scrolling and finding, on the chords libghostty already used, so naming the action is
        // invisible to anyone already pressing them.
        //
        // The four scroll keys are `Chord`'s glyph tokens, which is what a live event resolves to:
        // Home, End, Page Up and Page Down type no character. A config file spells them as words.
        map[Chord(command: true, key: "↖")] = .scrollToTop
        map[Chord(command: true, key: "↘")] = .scrollToBottom
        map[Chord(command: true, key: "⇞")] = .scrollPageUp
        map[Chord(command: true, key: "⇟")] = .scrollPageDown
        map[Chord(command: true, key: "e")] = .searchSelection

        // The screen and the prompt marks, again on libghostty's own chords.
        //
        // The prompt jumps take ghostty's shifted spelling, not its bare one: macOS claims ⌘↑ and
        // ⌘↓, so the bare pair never reaches the app and would sit in the Shortcuts card and the
        // reference config as advice that does nothing.
        map[Chord(command: true, key: "k")] = .clearScreen
        map[Chord(command: true, key: "j")] = .scrollToSelection
        map[Chord(command: true, shift: true, key: "j")] = .writeScreenFile
        map[Chord(command: true, shift: true, control: true, key: "j")] = .copyScreenFilePath
        map[Chord(command: true, shift: true, option: true, key: "j")] = .openScreenFile

        // Select All ships no chord: the Edit menu holds ⌘A, and a menu key equivalent serves a
        // focused text field and a pane both, which the keymap cannot. `KeyInterceptor` resolves
        // ahead of the responder chain, so a default here would take ⌘A off every field in the app.
        //
        // The menu owning it costs two things: any bind landing on ⌘A is refused, and
        // `select_all=none` cannot free the chord, because a key equivalent is not the keymap's to
        // unbind.
        map[Chord(command: true, shift: true, key: "v")] = .pasteSelection
        map[Chord(command: true, shift: true, key: "↑")] = .jumpToPreviousPrompt
        map[Chord(command: true, shift: true, key: "↓")] = .jumpToNextPrompt

        // Clearing notices. N for notice, beside ⌘N's window family rather than in it — the toast
        // stack is the only thing in the app these two touch.
        map[Chord(command: true, shift: true, key: "n")] = .dismissToast
        map[Chord(command: true, shift: true, option: true, key: "n")] = .dismissAllToasts

        return map
    }()
}

/// The reserved-action keymap as something that can be written back: the chords each action holds,
/// plus the actions that hold none on purpose.
///
/// The second half is why this type exists. An unbound action cannot appear in a `[Chord: Action]`
/// map, and its absence is indistinguishable from "at its defaults", which silently deleted the
/// user's `= none` line on the next Settings write.
///
/// **Edit through `bind` / `unbind`**, not the two properties: five paths change a binding, and
/// hand-editing both collections is where the halves drift into claiming an action is bound *and*
/// deliberately unbound.
struct KeymapOverrides: Equatable {
    var binds: [Chord: KeyInterceptor.ReservedChord]
    var unbound: Set<KeyInterceptor.ReservedChord>

    init(binds: [Chord: KeyInterceptor.ReservedChord] = [:], unbound: Set<KeyInterceptor.ReservedChord> = []) {
        self.binds = binds
        self.unbound = unbound
    }

    /// Give `action` exactly `chords` and nothing else, and stop calling it unbound.
    mutating func bind(_ action: KeyInterceptor.ReservedChord, to chords: some Sequence<Chord>) {
        binds = binds.filter { $0.value != action }
        for chord in chords { binds[chord] = action }
        unbound.remove(action)
    }

    /// Take every chord off `action` and record that it is meant to have none.
    mutating func unbind(_ action: KeyInterceptor.ReservedChord) {
        binds = binds.filter { $0.value != action }
        unbound.insert(action)
    }

    /// Forget everything this set says about `action`, so the writer emits no line for it and the
    /// assembler hands it its defaults on the next load.
    ///
    /// Distinct from `bind(_:to:)` with the defaults, which reaches the same end state by writing
    /// chords in, and `binds` is keyed by chord: writing a default chord in evicts whatever else
    /// held it. Distinct from `unbind` too, which records the absence rather than forgetting it.
    mutating func clearOverride(_ action: KeyInterceptor.ReservedChord) {
        binds = binds.filter { $0.value != action }
        unbound.remove(action)
    }

    /// The chords `action` holds here.
    func chords(of action: KeyInterceptor.ReservedChord) -> Set<Chord> {
        Set(binds.filter { $0.value == action }.map(\.key))
    }

    /// What `config` resolves to, as the set a write regenerates the keybind block from.
    init(config: GeneralConfig) {
        self.init(binds: Self.reserved(in: config.keymap), unbound: config.unboundActions)
    }

    /// Every action back on the chords it ships with, for "Reset all to defaults".
    init(defaults: [Chord: KeyInterceptor.ReservedChord]) {
        self.init(binds: Self.reserved(in: defaults))
    }

    /// A map without the user floats' toggles. A user float's chord lives on its own `float =`
    /// line, so emitting it here would write a second copy that the two halves could then disagree
    /// about. One rule, applied wherever a map becomes a set the writer may emit.
    ///
    /// The built-in Scratch float stays: it has no `float =` line, so a `keybind =` line is the
    /// only place its rebind can live, and dropping it here would delete that line on the next
    /// unrelated Shortcuts edit.
    private static func reserved(
        in map: [Chord: KeyInterceptor.ReservedChord]
    ) -> [Chord: KeyInterceptor.ReservedChord] {
        map.filter {
            if case .toggleToolFloat(let id) = $0.value { return ToolFloat.isBuiltIn(id) }
            return true
        }
    }
}

/// Parses a single `keybind =` value, e.g. `toggle_workspace_picker=cmd+shift+p`.
enum KeybindParser {
    /// What one line asks for. An unbind is a value rather than the absence of a chord, because
    /// every stage downstream has to tell "the user wants no shortcut here" apart from "nothing
    /// was said about this action".
    enum Line: Equatable {
        case bind(Chord, KeyInterceptor.ReservedChord)
        case unbind(KeyInterceptor.ReservedChord)
    }

    /// The words that mean "no chord". `none` is ours; `unbind` is ghostty's, accepted because it
    /// is the word a ghostty user reaches for. Note that ghostty's own line reads trigger-first
    /// (`cmd+g=unbind`), so that spelling is still an unknown action here. The word carries over,
    /// the line shape does not.
    private static let unbindWords: Set<String> = ["none", "unbind"]

    /// Split on the FIRST `=` (action LHS, chord RHS — the action reads first, mirroring the
    /// "behavior, then key" phrasing). Returns `nil` (caller warns + skips) on an unknown
    /// action or an unparseable chord.
    ///
    /// An empty RHS stays unparseable rather than meaning `none`: a trailing `=` is something you
    /// type by accident, and reading it as a deliberate unbind would silently take a shortcut away.
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

/// Folds the defaults, the floats' own `key:` chords, and the user's `keybind` lines into one
/// resolved keymap. Resolution order (later wins, a displacing write is logged): defaults →
/// float chords → user keybinds. A `toggle_float:<id>` keybind whose id isn't a loaded float
/// is skipped with a warning.
///
/// Also reports the displacements that cost an action its *last* chord, so the Keybinds card can
/// say why a row has no shortcut rather than rendering a bare empty chip.
enum KeymapAssembler {
    /// What a config assembled to. A struct rather than a tuple because the third member is not
    /// derivable from the first two: an action holding no chord in `map` is either something the
    /// user asked for or something a collision did to them, and only this can tell you which.
    struct Assembled {
        let map: [Chord: KeyInterceptor.ReservedChord]
        /// The actions a `= none` line named that ended with no chord. Both halves of
        /// that matter. An action left chordless by a *displacement* stays out, or the writer would
        /// turn a reported conflict into a silent intentional unbind; an action with both a `= none`
        /// line and a real bind stays out too, since the bind won and writing the contradiction back
        /// would round-trip it forever.
        let unbound: Set<KeyInterceptor.ReservedChord>
        let diagnostics: [ConfigDiagnostic]
    }

    /// `canType` is injected so tests state the layout instead of inheriting the test machine's.
    /// Its type is `@MainActor` deliberately: a plain `(Chord) -> Bool` parameter erases the leaf's
    /// isolation, so annotating `KeyboardLayout.canType` alone would let an off-main assembly
    /// compile clean straight past it.
    @MainActor
    static func assemble(
        floats: [ToolFloat], keybinds: [KeybindParser.Line],
        canType: @MainActor (Chord) -> Bool = KeyboardLayout.canType,
        protected: @MainActor () -> Set<Chord> = MenuShortcuts.protected,
        menuOwner: @MainActor (Chord) -> String? = MenuShortcuts.owner
    ) -> Assembled {
        var map = KeymapDefaults.map
        // `floats` is what the config parsed, which never includes the built-in. Union it in, or a
        // `toggle_float:scratch` line is dropped below as naming no float.
        let floatIDs = Set(floats.map(\.id)).union(ToolFloat.builtInIDs)
        var displacements: [Displacement] = []
        let menuChords = protected()

        // A user float's chord lives on its `float =` line, whose `key:` is required, so an unbind
        // naming one would be a no-op that reads as working: the float re-binds the chord a few
        // lines below. Refused where the unknown-float-id line is refused, and for the same reason.
        //
        // The built-in's chord comes from `KeymapDefaults`, which `requestedUnbinds` drops below,
        // so its `= none` is real and is honored.
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

        // Drop binds no keypress on this keyboard could ever produce (`cmd+|` on a US layout — `|`
        // needs Shift there), and binds on a chord the menu bar owns. Both dropped BEFORE
        // `reboundActions`, so a refused line doesn't also cost the action its default: the old
        // behavior left it with no shortcut at all, and the dead chord in the map made it look
        // bound. Both lists carry to the diagnostics.
        //
        // The menu case is not a preference. `KeyInterceptor` resolves before `NSApp.sendEvent`, so
        // a bind on ⌘Q would win and Quit would stop working with the menu still drawing ⌘Q beside
        // it. Refusing is the only outcome the user can see.
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

        // A user keybind MOVES its action: drop the action's default chord(s) first, so the
        // old key is freed instead of both the default and the new chord firing it. An unbind drops
        // them the same way and puts nothing back.
        //
        // Dropping the unbinds HERE, ahead of every `set()` below, is the whole mechanism behind an
        // explicit unbind being silent: the chord is already free when a float or a later line
        // claims it, so no displacement is recorded and there is nothing for `diagnostics` to
        // report. Move this after the writes and the user gets told off for a config they wrote on
        // purpose.
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

        // A float's own `key:` is refused on the same grounds, and reported as the float's problem
        // rather than a keybind's: the user wrote it on the `float =` line, which is where they
        // have to go to fix it.
        //
        // A built-in never comes through here even if one is passed in: its chord is a default, so
        // re-setting it would undo the `= none` above, and a menu collision would be reported on a
        // Tools row it does not have.
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

    /// A config line naming a chord the menu bar owns. Its own headline rather than the untypeable
    /// one: the chord is perfectly typeable, and the reason it was refused is a thing the user can
    /// see for themselves in the menu.
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
                // `.toolFloatField`, not `.toolFloat`: the latter is for a `float =` line that
                // never became a float, and Settings renders it as a section-level "ignored"
                // notice. This float still works and still has a row, so the row carries it.
                ConfigDiagnostic(
                    scope: .toolFloatField(id: float.id, label: float.title),
                    problem: .floatMenuKey(float.toggle, menuItem: owner(float.toggle)))
            }
    }

    /// A config line naming a chord this keyboard can't produce. Distinct from an action left with
    /// no shortcut: the action still has its default — it's the line that's dead — so it gets its
    /// own headline rather than borrowing the "no shortcut" one.
    private static func untypeableDiagnostics(
        _ untypeable: [(Chord, KeyInterceptor.ReservedChord)]
    ) -> [ConfigDiagnostic] {
        untypeable.map { chord, action in
            ConfigDiagnostic(scope: .keybind(action), problem: .unusableBind(chord))
        }
    }

    /// One chord write that took a chord off another action — recorded as it happens, before the
    /// final map says whether the loser was left with anything else. Deliberately does NOT record
    /// the winner: a later write can take the same chord off it, so the only trustworthy answer is
    /// read back from the finished map. Storing one here would invite exactly the bug that cost.
    private struct Displacement {
        let chord: Chord
        let loser: KeyInterceptor.ReservedChord
    }

    /// A displacement is only worth surfacing when it took the loser's *last* chord — losing one of
    /// two bindings is a rebind working as intended, but losing the only one leaves an action
    /// silently unreachable. Reported once per action, naming the first chord it lost.
    ///
    /// The winner is read back from the finished `map`, not from what was recorded at write time: a
    /// third line can take the same chord off the recorder's winner (last-wins), and the message
    /// names the token the user has to go edit — pointing at a line that no longer holds the chord
    /// would send them to fix the wrong one.
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
    /// The remainder after `prefix`, or `nil` if `self` doesn't start with it.
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
