import AppKit

/// A parsed keyboard chord — a set of modifiers plus one key. The shared currency between
/// the config file (`cmd+shift+g`), the display glyph (`⌘⇧G`), and live `NSEvent` matching
/// in `KeyInterceptor`. Value-typed and `Hashable` so a `[Chord: ReservedChord]` keymap is
/// a plain dictionary lookup.
struct Chord: Hashable {
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool
    /// Canonical, lowercased single key token — always the key's *unshifted* glyph: `"g"`, `"1"`,
    /// `"\\"`, `"-"`. A shifted glyph (`"|"`, `"_"`, `"!"`) never survives `init`; see `shift`.
    var key: String

    /// Canonicalizes: a glyph a US key only produces with Shift held folds onto its base key with
    /// `shift` set, so one physical key has exactly one spelling. `charactersIgnoringModifiers`
    /// applies Shift, so a live ⌘⇧- press arrives as `_` while the config spells the same chord
    /// `cmd+shift+-` — folding both onto ⇧`-` makes them the same dictionary key, which is what
    /// lets the keymap hold one entry per binding instead of one per spelling. It also rescues a
    /// hand-written `cmd+|`, which no US keyboard can produce without Shift.
    init(command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false, key: String) {
        self.command = command
        self.option = option
        self.control = control
        if let base = Chord.baseKeyForShiftedGlyph[key] {
            self.shift = true
            self.key = base
        } else {
            self.shift = shift
            self.key = key
        }
    }

    /// The unshifted glyph for every key a US layout shifts into a different character. One-way by
    /// design (shifted → base): the base key is the canonical spelling, so nothing maps back.
    private static let baseKeyForShiftedGlyph: [String: String] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
        "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-",
        "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'",
        "<": ",", ">": ".", "?": "/",
    ]

    /// Parse `cmd+shift+g` → a `Chord`, or `nil` if the spec is malformed (no key, two keys,
    /// or an unknown modifier word). Accepts ghostty-style aliases so a pasted ghostty
    /// keybind mostly works: `cmd`/`command`, `shift`, `opt`/`option`/`alt`, `ctrl`/`control`.
    static func parse(_ spec: String) -> Chord? {
        var command = false
        var shift = false
        var option = false
        var control = false
        var key: String?
        // Keep empty subsequences so a stray `++` or trailing `+` (e.g. "cmd++g", "nope+")
        // is rejected rather than silently collapsed.
        for rawToken in spec.split(separator: "+", omittingEmptySubsequences: false) {
            let token = rawToken.trimmingCharacters(in: .whitespaces).lowercased()
            guard !token.isEmpty else { return nil }
            switch token {
            case "cmd", "command", "super": command = true
            case "shift": shift = true
            case "opt", "option", "alt": option = true
            case "ctrl", "control": control = true
            default:
                if key != nil { return nil }  // two non-modifier tokens → ambiguous
                // `+` is the token separator, so it can't travel literally; ghostty spells it
                // `plus`, and configs in the wild do too. Accepted as an input alias only —
                // `init` folds `+` onto ⇧`=`, so `configToken` emits `cmd+shift+=` on the way out.
                key = (token == "plus") ? "+" : token
            }
        }
        guard let key else { return nil }
        // A live event's key is a single `charactersIgnoringModifiers` character, so a
        // multi-char token (e.g. "space") could never match — reject it as a dead bind.
        guard key.count == 1 else { return nil }
        // A modifier-less chord would swallow that plain keystroke from the terminal for
        // every keypress — reserved chords must carry at least one modifier. This reads the
        // *spelled* modifiers, deliberately ahead of the Shift `init` infers for a shifted glyph:
        // a bare `_` must stay rejected rather than canonicalize into a ⇧- that eats every
        // underscore typed into the terminal.
        guard command || shift || option || control else { return nil }
        return Chord(command: command, shift: shift, option: option, control: control, key: key)
    }

    /// The display form the chrome renders (`⌘⇧G`) — modifiers in the repo's established
    /// order (⌘ ⇧ ⌥ ⌃), then the key: letters uppercased, symbols/digits as-is. `KeycapView`
    /// turns the modifier glyphs into SF Symbols.
    var displayGlyph: String {
        Chord.modifierGlyph(command: command, shift: shift, option: option, control: control)
            + (key.count == 1 ? key.uppercased() : key)
    }

    /// The modifier glyphs in the repo's established order (⌘ ⇧ ⌥ ⌃) — the one place that order
    /// lives, shared by `displayGlyph` and the keybind capture's live modifier preview.
    static func modifierGlyph(command: Bool, shift: Bool, option: Bool, control: Bool) -> String {
        var glyph = ""
        if command { glyph += "⌘" }
        if shift { glyph += "⇧" }
        if option { glyph += "⌥" }
        if control { glyph += "⌃" }
        return glyph
    }

    /// The modifier glyphs for a live `NSEvent`'s flags — same ⌘⇧⌥⌃ order as `displayGlyph`.
    static func modifierGlyph(_ flags: NSEvent.ModifierFlags) -> String {
        modifierGlyph(
            command: flags.contains(.command), shift: flags.contains(.shift),
            option: flags.contains(.option), control: flags.contains(.control))
    }

    /// The config-file word form the writer emits (`cmd+shift+g`) — modifiers in the
    /// repo's order (cmd, shift, opt, ctrl) then the key. A *projection* of `parse`, not its
    /// inverse: several spellings canonicalize to one chord (`cmd+shift+_`, `cmd+shift+-` and
    /// `cmd+_` all emit `cmd+shift+-`), so a re-parse of the output is stable from here on.
    /// Mirrors `displayGlyph`'s glyph form.
    var configToken: String {
        var token = ""
        if command { token += "cmd+" }
        if shift { token += "shift+" }
        if option { token += "opt+" }
        if control { token += "ctrl+" }
        // No escaping needed for the `+` separator: `key` is canonical, and `+` folds onto ⇧`=`.
        return token + key
    }

    /// Build the chord an `NSEvent` represents, for keymap lookup. Mirrors the modifier +
    /// `charactersIgnoringModifiers` reading `KeyInterceptor` used before it went data-driven.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key: String
        if let special = Chord.glyphForSpecialKey(event.keyCode) {
            key = special  // arrow / return keys carry a non-printing character — use a glyph token
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

    /// Keys whose `charactersIgnoringModifiers` is a non-printing character render as tofu (□) — map
    /// them to a display glyph, which `KeycapView` draws as an SF Symbol and `configToken`/`parse`
    /// round-trip as a single character.
    private static func glyphForSpecialKey(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 36: return "⏎"
        default: return nil
        }
    }
}
