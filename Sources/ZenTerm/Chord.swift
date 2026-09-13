import AppKit

struct Chord: Hashable {
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool
    var key: String

    /// Folds a shifted glyph onto its base key only with Shift held: non-US layouts type these glyphs unshifted.
    init(command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false, key: String) {
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
        let key = key.lowercased()
        self.key = (shift ? Chord.baseKeyForShiftedGlyph[key] : nil) ?? key
    }

    private static let baseKeyForShiftedGlyph: [String: String] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
        "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-",
        "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'",
        "<": ",", ">": ".", "?": "/",
    ]

    /// Accepts ghostty's modifier and key spellings, so a pasted ghostty keybind resolves.
    static func parse(_ spec: String) -> Chord? {
        var command = false
        var shift = false
        var option = false
        var control = false
        var key: String?
        for rawToken in spec.split(separator: "+", omittingEmptySubsequences: false) {
            let token = rawToken.trimmingCharacters(in: .whitespaces).lowercased()
            guard !token.isEmpty else { return nil }
            switch token {
            case "cmd", "command", "super": command = true
            case "shift": shift = true
            case "opt", "option", "alt": option = true
            case "ctrl", "control": control = true
            default:
                if key != nil { return nil }
                key = Chord.specialKeyWords[token] ?? ((token == "plus") ? "+" : token)
            }
        }
        guard let key else { return nil }
        guard key.count == 1 else { return nil }
        guard command || shift || option || control else { return nil }
        return Chord(command: command, shift: shift, option: option, control: control, key: key)
    }

    var displayGlyph: String {
        Chord.modifierGlyph(command: command, shift: shift, option: option, control: control)
            + (key.count == 1 ? key.uppercased() : key)
    }

    static func modifierGlyph(command: Bool, shift: Bool, option: Bool, control: Bool) -> String {
        var glyph = ""
        if command { glyph += "⌘" }
        if shift { glyph += "⇧" }
        if option { glyph += "⌥" }
        if control { glyph += "⌃" }
        return glyph
    }

    static func modifierGlyph(_ flags: NSEvent.ModifierFlags) -> String {
        modifierGlyph(
            command: flags.contains(.command), shift: flags.contains(.shift),
            option: flags.contains(.option), control: flags.contains(.control))
    }

    /// Writes `+` as `plus` and special keys as words: `+` separates tokens, and nobody can type ↖ into a file.
    var configToken: String {
        var token = ""
        if command { token += "cmd+" }
        if shift { token += "shift+" }
        if option { token += "opt+" }
        if control { token += "ctrl+" }
        if key == "+" { return token + "plus" }
        return token + (Chord.wordForSpecialKey[key] ?? key)
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key: String
        if let special = Chord.glyphForSpecialKey(event.keyCode) {
            key = special
        } else {
            guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else {
                return nil
            }
            key = characters
        }
        self.init(
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control),
            key: key)
    }

    /// Picks the lowest `configToken`, so every surface names the same chord across launches.
    static func displayed(
        _ action: KeyInterceptor.ReservedChord, in keymap: [Chord: KeyInterceptor.ReservedChord]
    ) -> Chord? {
        keymap.filter { $0.value == action }.keys.min { $0.configToken < $1.configToken }
    }

    private static func glyphForSpecialKey(_ keyCode: UInt16) -> String? {
        specialKeyGlyphs[keyCode]
    }

    /// Includes Tab: its character is `\t`, which renders blank on a keycap and in a config file.
    private static let specialKeyGlyphs: [UInt16: String] = [
        123: "←", 124: "→", 125: "↓", 126: "↑", 36: "⏎",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 48: "⇥", 51: "⌫",
    ]

    private static let specialKeyWords: [String: String] = [
        "left": "←", "right": "→", "down": "↓", "up": "↑",
        "arrow_left": "←", "arrow_right": "→", "arrow_down": "↓", "arrow_up": "↑",
        "enter": "⏎", "return": "⏎",
        "home": "↖", "end": "↘", "page_up": "⇞", "page_down": "⇟",
        "tab": "⇥",
        "backspace": "⌫",
    ]

    private static let wordForSpecialKey: [String: String] = [
        "←": "left", "→": "right", "↓": "down", "↑": "up", "⏎": "enter",
        "↖": "home", "↘": "end", "⇞": "page_up", "⇟": "page_down", "⇥": "tab",
        "⌫": "backspace",
    ]

    static func keyCodeForSpecialGlyph(_ key: String) -> UInt16? {
        specialKeyGlyphs.first { $0.value == key }?.key
    }
}
