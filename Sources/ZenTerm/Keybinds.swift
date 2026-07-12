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
        case .toggleZoom: return "toggle_zoom"
        case .toggleLazygit: return "toggle_lazygit"
        case .toggleToolFloat(let id): return "toggle_float:\(id)"
        case .toggleRepoPicker: return "toggle_repo_picker"
        case .toggleCommandPalette: return "toggle_command_palette"
        case .addWorkspace: return "add_workspace"
        case .openSettings: return "open_settings"
        case .reloadConfig: return "reload_config"
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
        case "toggle_zoom": self = .toggleZoom
        case "toggle_lazygit": self = .toggleLazygit
        case "toggle_repo_picker": self = .toggleRepoPicker
        case "toggle_command_palette": self = .toggleCommandPalette
        case "add_workspace": self = .addWorkspace
        case "open_settings": self = .openSettings
        case "reload_config": self = .reloadConfig
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

        // ⌘⇧ family — vertical split (both the shifted "|" and defensive "\\"), pane/drawer
        // resize on HJKL, repo picker.
        map[Chord(command: true, shift: true, key: "|")] = .splitVertical
        map[Chord(command: true, shift: true, key: "\\")] = .splitVertical
        map[Chord(command: true, shift: true, key: "h")] = .resizeLeft
        map[Chord(command: true, shift: true, key: "l")] = .resizeRight
        map[Chord(command: true, shift: true, key: "k")] = .resizeUp
        map[Chord(command: true, shift: true, key: "j")] = .resizeDown
        map[Chord(command: true, shift: true, key: "p")] = .toggleRepoPicker

        // bare ⌘.
        map[Chord(command: true, key: "\\")] = .toggleRightDrawer
        map[Chord(command: true, key: "[")] = .prevTab
        map[Chord(command: true, key: "]")] = .nextTab
        map[Chord(command: true, key: "-")] = .splitHorizontal
        map[Chord(command: true, key: "h")] = .navLeft
        map[Chord(command: true, key: "l")] = .navRight
        map[Chord(command: true, key: "k")] = .navUp
        map[Chord(command: true, key: "j")] = .navDown
        map[Chord(command: true, key: "w")] = .closePane
        map[Chord(command: true, key: "t")] = .newTab
        map[Chord(command: true, key: "n")] = .newWindow
        map[Chord(command: true, key: "b")] = .toggleBottomDrawer
        map[Chord(command: true, key: "f")] = .toggleZoom
        map[Chord(command: true, key: "g")] = .toggleLazygit
        map[Chord(command: true, key: "p")] = .toggleCommandPalette
        map[Chord(command: true, key: ",")] = .openSettings
        map[Chord(command: true, option: true, key: "r")] = .reloadConfig
        for n in 1...9 { map[Chord(command: true, key: "\(n)")] = .selectTab(n) }

        return map
    }()
}

/// Parses a single `keybind =` value, e.g. `toggle_repo_picker=cmd+shift+p`.
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
enum KeymapAssembler {
    static func assemble(
        floats: [ToolFloat], keybinds: [(Chord, KeyInterceptor.ReservedChord)]
    ) -> [Chord: KeyInterceptor.ReservedChord] {
        var map = KeymapDefaults.map
        let floatIDs = Set(floats.map(\.id))

        // A user keybind MOVES its action: drop the action's default chord(s) first, so the
        // old key is freed instead of both the default and the new chord firing it.
        let reboundActions = keybinds.map(\.1)
        map = map.filter { entry in !reboundActions.contains(entry.value) }

        func set(_ chord: Chord, _ action: KeyInterceptor.ReservedChord) {
            if let existing = map[chord], existing != action {
                NSLog(
                    "GeneralConfig: chord \(chord.displayGlyph) rebound from \(existing.actionToken) "
                        + "to \(action.actionToken)")
            }
            map[chord] = action
        }

        for float in floats { set(float.toggle, .toggleToolFloat(float.id)) }
        for (chord, action) in keybinds {
            if case .toggleToolFloat(let id) = action, !floatIDs.contains(id) {
                NSLog("GeneralConfig: keybind action toggle_float:\(id) names no configured float — ignored")
                continue
            }
            set(chord, action)
        }
        return map
    }
}

private extension String {
    /// The remainder after `prefix`, or `nil` if `self` doesn't start with it.
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
