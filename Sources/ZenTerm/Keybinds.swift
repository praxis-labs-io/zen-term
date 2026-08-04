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
        case .openDiffViewer: return "diff_viewer"
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
        case .findNext: return "find_next"
        case .findPrevious: return "find_previous"
        case .searchSelection: return "search_selection"
        }
    }

    /// Whether holding the chord down should fire the action again at the key-repeat rate.
    ///
    /// Only the actions whose effect accumulates toward something the eye tracks, and where the
    /// hold runs out of room on its own: nav stops at the edge pane, resize at the pane's minimum,
    /// font size at the scale limit, a page scroll at the end of the buffer. Everything else is a
    /// discrete act, and a held ⌘N spawning windows at 30 a second is the bug this answers. Tab
    /// cycling and search stepping are deliberately not here: both wrap, so a hold never lands
    /// anywhere the user aimed.
    ///
    /// A `switch` so a new `ReservedChord` case has to answer, the same as `actionToken`.
    var shouldRepeat: Bool {
        switch self {
        case .navLeft, .navRight, .navUp, .navDown: return true
        case .resizeLeft, .resizeRight, .resizeUp, .resizeDown: return true
        case .increaseFontSize, .decreaseFontSize: return true
        case .scrollPageUp, .scrollPageDown: return true
        case .splitVertical, .splitHorizontal, .closePane, .newTab, .newWindow, .selectTab,
            .prevTab, .nextTab, .toggleBottomDrawer, .toggleRightDrawer, .toggleZoom, .fillScreen,
            .toggleToolFloat, .toggleRepoPicker, .toggleCommandPalette, .openSettings,
            .reloadConfig, .checkForUpdates, .reportIssue, .openDiffViewer, .resetFontSize,
            .toggleScrollMode, .toggleSearch, .scrollToTop, .scrollToBottom,
            .findNext, .findPrevious, .searchSelection:
            return false
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
        // Back-compat: the action was renamed from zoom to Focus Mode (ZEN-207); an existing
        // config with the old token still resolves rather than silently dropping the binding.
        case "toggle_zoom": self = .toggleZoom
        case "fill_screen": self = .fillScreen
        case "toggle_workspace_picker": self = .toggleRepoPicker
        // Back-compat: the config token is `toggle_workspace_picker` (ZEN-6) — the product calls it
        // a workspace everywhere, and `repo` was the one token whose product name moved on. The old
        // `toggle_repo_picker` still resolves so an existing binding keeps working.
        case "toggle_repo_picker": self = .toggleRepoPicker
        case "toggle_command_palette": self = .toggleCommandPalette
        case "open_settings": self = .openSettings
        case "reload_config": self = .reloadConfig
        case "check_for_updates": self = .checkForUpdates
        case "report_issue": self = .reportIssue
        case "diff_viewer": self = .openDiffViewer
        case "increase_font_size": self = .increaseFontSize
        case "decrease_font_size": self = .decreaseFontSize
        case "reset_font_size": self = .resetFontSize
        case "toggle_scroll_mode": self = .toggleScrollMode
        case "toggle_search": self = .toggleSearch
        case "scroll_to_top": self = .scrollToTop
        case "scroll_to_bottom": self = .scrollToBottom
        case "scroll_page_up": self = .scrollPageUp
        case "scroll_page_down": self = .scrollPageDown
        case "find_next": self = .findNext
        case "find_previous": self = .findPrevious
        case "search_selection": self = .searchSelection
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

/// The built-in chord → action map, exactly reproducing the pre-ZEN-71 hardcoded
/// `KeyInterceptor` switch. The user's `keybind` lines and float `key:` chords overlay this.
/// Note the old `⌘⇧G → gitdash` line is intentionally absent — a float's chord now comes
/// from its own `key:` field, so no float is built in.
enum KeymapDefaults {
    static let map: [Chord: KeyInterceptor.ReservedChord] = {
        var map: [Chord: KeyInterceptor.ReservedChord] = [:]

        // ⌘⇧ family — the splits, pane/drawer resize on HJKL, repo picker. Both splits are spelled
        // with the *unshifted* key: `Chord` canonicalizes, so a live ⌘⇧\ event (which arrives as
        // "|") and a live ⌘⇧- event (which arrives as "_") already fold onto these entries. ⌘⇧-
        // rather than bare ⌘- dates from ZEN-121, which left bare ⌘- to libghostty's own text
        // magnification; ZEN-224 took that chord over, and ⌘⇧- stays split on its own merits.
        map[Chord(command: true, shift: true, key: "\\")] = .splitVertical
        map[Chord(command: true, shift: true, key: "-")] = .splitHorizontal
        map[Chord(command: true, shift: true, key: "h")] = .resizeLeft
        map[Chord(command: true, shift: true, key: "l")] = .resizeRight
        map[Chord(command: true, shift: true, key: "k")] = .resizeUp
        map[Chord(command: true, shift: true, key: "j")] = .resizeDown
        map[Chord(command: true, shift: true, key: "p")] = .toggleRepoPicker
        map[Chord(command: true, shift: true, key: "f")] = .fillScreen
        map[Chord(command: true, shift: true, key: "s")] = .toggleScrollMode
        // vim's search key. ⌘F is Focus Mode and stays there; ⌘? folds to "/" carrying shift, so it
        // is a separate chord and this does not claim it.
        map[Chord(command: true, key: "/")] = .toggleSearch

        // bare ⌘.
        map[Chord(command: true, key: "\\")] = .toggleRightDrawer
        map[Chord(command: true, key: "[")] = .prevTab
        map[Chord(command: true, key: "]")] = .nextTab
        map[Chord(command: true, key: "h")] = .navLeft
        map[Chord(command: true, key: "l")] = .navRight
        map[Chord(command: true, key: "k")] = .navUp
        map[Chord(command: true, key: "j")] = .navDown
        map[Chord(command: true, key: "w")] = .closePane
        map[Chord(command: true, key: "t")] = .newTab
        map[Chord(command: true, key: "n")] = .newWindow
        map[Chord(command: true, key: "b")] = .toggleBottomDrawer
        map[Chord(command: true, key: "f")] = .toggleZoom
        map[Chord(command: true, key: "p")] = .toggleCommandPalette
        map[Chord(command: true, key: ",")] = .openSettings
        map[Chord(command: true, key: "d")] = .openDiffViewer  // open the diff viewer
        map[Chord(command: true, option: true, key: "r")] = .reloadConfig
        for n in 1...9 { map[Chord(command: true, key: "\(n)")] = .selectTab(n) }

        // Font size (ZEN-224), matching what libghostty bound before the chrome took these over.
        //
        // Increase needs BOTH entries, and the second is the one that matters: "⌘+" on a US layout
        // is physically ⌘⇧=, and `Chord` folds the "+" it arrives as back onto "=" because Shift is
        // set. Bind ⌘= alone and the keypress most people actually make falls through to libghostty,
        // which still has it bound per surface — reproducing this exact ticket. Two defaults for one
        // action is fine: `assemble` drops all of an action's defaults when the user rebinds it, and
        // `Chord.displayed` sorts by config token, so a keycap renders the plainer ⌘=.
        map[Chord(command: true, key: "=")] = .increaseFontSize
        map[Chord(command: true, shift: true, key: "=")] = .increaseFontSize
        map[Chord(command: true, key: "-")] = .decreaseFontSize
        map[Chord(command: true, key: "0")] = .resetFontSize

        // Scrolling and finding (ZEN-367), on the chords libghostty already used for them. Every
        // one was live under a pane and answered by the backend rather than by us, so keeping the
        // chord is what makes naming the action invisible to anyone already pressing it.
        //
        // The four scroll keys are `Chord`'s glyph tokens, which is what a live event resolves to:
        // Home, End, Page Up and Page Down type no character, so the keyCode table is the only way
        // to name them. A config file spells the same four as words.
        map[Chord(command: true, key: "↖")] = .scrollToTop
        map[Chord(command: true, key: "↘")] = .scrollToBottom
        map[Chord(command: true, key: "⇞")] = .scrollPageUp
        map[Chord(command: true, key: "⇟")] = .scrollPageDown
        map[Chord(command: true, key: "g")] = .findNext
        map[Chord(command: true, shift: true, key: "g")] = .findPrevious
        map[Chord(command: true, key: "e")] = .searchSelection

        return map
    }()
}

/// Parses a single `keybind =` value, e.g. `toggle_workspace_picker=cmd+shift+p`.
enum KeybindParser {
    /// Split on the FIRST `=` (action LHS, chord RHS — the action reads first, mirroring the
    /// "behavior, then key" phrasing). Returns `nil` (caller warns + skips) on an unknown
    /// action or an unparseable chord.
    static func parse(_ value: String) -> (Chord, KeyInterceptor.ReservedChord)? {
        guard let equals = value.firstIndex(of: "=") else { return nil }
        let lhs = value[..<equals].trimmingCharacters(in: .whitespaces)
        let rhs = value[value.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard let action = KeyInterceptor.ReservedChord(token: lhs), let chord = Chord.parse(rhs) else {
            return nil
        }
        return (chord, action)
    }
}

/// Folds the defaults, the floats' own `key:` chords, and the user's `keybind` lines into one
/// resolved keymap. Resolution order (later wins, a displacing write is logged): defaults →
/// float chords → user keybinds. A `toggle_float:<id>` keybind whose id isn't a loaded float
/// is skipped with a warning.
///
/// Also reports the displacements that cost an action its *last* chord, so the Keybinds card can
/// say why a row has no shortcut rather than rendering a bare empty chip (ZEN-121).
enum KeymapAssembler {
    /// `canType` is injected so tests state the layout instead of inheriting the test machine's.
    /// Its type is `@MainActor` deliberately: a plain `(Chord) -> Bool` parameter erases the leaf's
    /// isolation, so annotating `KeyboardLayout.canType` alone would let an off-main assembly
    /// compile clean straight past it (ZEN-31).
    @MainActor
    static func assemble(
        floats: [ToolFloat], keybinds: [(Chord, KeyInterceptor.ReservedChord)],
        canType: @MainActor (Chord) -> Bool = KeyboardLayout.canType,
        protected: @MainActor () -> Set<Chord> = MenuShortcuts.protected,
        menuOwner: @MainActor (Chord) -> String? = MenuShortcuts.owner
    ) -> (map: [Chord: KeyInterceptor.ReservedChord], diagnostics: [ConfigDiagnostic]) {
        var map = KeymapDefaults.map
        let floatIDs = Set(floats.map(\.id))
        var displacements: [Displacement] = []
        let menuChords = protected()

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
        for bind in keybinds {
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
        // old key is freed instead of both the default and the new chord firing it.
        let reboundActions = typeable.map(\.1)
        map = map.filter { entry in !reboundActions.contains(entry.value) }

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
        var menuOwnedFloats: [ToolFloat] = []
        for float in floats {
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
        return (
            map,
            diagnostics(for: displacements, in: map) + untypeableDiagnostics(untypeable)
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
