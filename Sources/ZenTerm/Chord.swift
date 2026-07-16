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
    /// Lowercased single key token: `"g"`, `"1"`, `"\\"`, `"-"`. Canonical *whenever Shift is set* —
    /// there it's always the unshifted glyph, because `init` folds `"|"` onto `⇧"\\"`. Without
    /// Shift the token is whatever was given: `cmd+|` stays `"|"`, since the fold table is US-only
    /// and these glyphs are unshifted on other layouts. Don't assume a base glyph; see `init`.
    var key: String

    /// Canonicalizes: **with Shift held**, a glyph that a US key produces only via Shift folds onto
    /// its base key, so one physical key has exactly one spelling. `charactersIgnoringModifiers`
    /// applies Shift, so a live ⌘⇧- press arrives as `_` while the config spells the same chord
    /// `cmd+shift+-` — folding both onto ⇧`-` makes them the same dictionary key, which is what lets
    /// the keymap hold one entry per binding instead of one per spelling.
    ///
    /// The Shift condition is load-bearing, not a formality: the table is US-only, and on other
    /// layouts these glyphs are reachable *without* Shift (`_` is an unshifted key on AZERTY, `+` on
    /// German QWERTZ). Folding on the glyph alone would give such a keypress a Shift its user never
    /// held and land it on ⌘⇧- — the split_horizontal default — swallowing a keystroke the terminal
    /// should have received. Gating on Shift means a non-US layout can at worst mis-*label* a chord,
    /// never invent one.
    init(command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false, key: String) {
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
        if shift, let base = Chord.baseKeyForShiftedGlyph[key] {
            self.key = base
        } else {
            self.key = key
        }
    }

    /// The unshifted glyph for each key a US layout shifts into a different character. One-way by
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
                // `+` is the token separator, so the plus key travels as the word `plus`
                // (ghostty's spelling too) — translate it back here. See `configToken`.
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
    /// inverse: with Shift held, several spellings fold to one chord (`cmd+shift+_` and
    /// `cmd+shift+-` both emit `cmd+shift+-`), so a re-parse of the output is stable from here on.
    /// Mirrors `displayGlyph`'s glyph form.
    var configToken: String {
        var token = ""
        if command { token += "cmd+" }
        if shift { token += "shift+" }
        if option { token += "opt+" }
        if control { token += "ctrl+" }
        // The plus key can't travel literally — `+` is the token separator, so `cmd++` would parse
        // as a stray empty token. Emit the word `plus`; `parse` maps it back. Only reachable
        // unshifted (⇧+ folds to ⇧=): a layout where `+` needs no Shift, or an explicit `cmd+plus`.
        return token + (key == "+" ? "plus" : key)
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

    /// The chord to show for an action, or nil when it's unbound. An action can hold several chords
    /// (a user binding two), and dictionary order is arbitrary — picking the lowest `configToken`
    /// keeps the palette, the dock tooltip, and the Settings chip naming the same one, instead of
    /// disagreeing with each other and drifting between launches.
    static func displayed(
        _ action: KeyInterceptor.ReservedChord, in keymap: [Chord: KeyInterceptor.ReservedChord]
    ) -> Chord? {
        keymap.filter { $0.value == action }.keys.min { $0.configToken < $1.configToken }
    }

    /// Keys whose `charactersIgnoringModifiers` is a non-printing character render as tofu (□) — map
    /// them to a display glyph, which `KeycapView` draws as an SF Symbol and `configToken`/`parse`
    /// round-trip as a single character.
    private static func glyphForSpecialKey(_ keyCode: UInt16) -> String? {
        specialKeyGlyphs[keyCode]
    }

    private static let specialKeyGlyphs: [UInt16: String] = [
        123: "←", 124: "→", 125: "↓", 126: "↑", 36: "⏎",
    ]

    /// Whether a key token is one of the non-printing keys `Chord(event:)` names by keyCode. These
    /// never come from the keyboard layout's character tables, so anything asking the layout what it
    /// can produce has to let them through — see `KeyboardLayout.canType`.
    static func isSpecialKeyGlyph(_ key: String) -> Bool {
        specialKeyGlyphs.values.contains(key)
    }
}
