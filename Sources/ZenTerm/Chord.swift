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
    /// Normalized, lowercased single key token: `"g"`, `"|"`, `"1"`, `"\\"`, `"-"`.
    var key: String

    init(command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false, key: String) {
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.key = key
    }

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
        // every keypress — reserved chords must carry at least one modifier.
        guard command || shift || option || control else { return nil }
        return Chord(command: command, shift: shift, option: option, control: control, key: key)
    }

    /// The display form the chrome renders (`⌘⇧G`) — modifiers in the repo's established
    /// order (⌘ ⇧ ⌥ ⌃), then the key: letters uppercased, symbols/digits as-is. `KeycapView`
    /// turns the modifier glyphs into SF Symbols.
    var displayGlyph: String {
        var glyph = ""
        if command { glyph += "⌘" }
        if shift { glyph += "⇧" }
        if option { glyph += "⌥" }
        if control { glyph += "⌃" }
        glyph += key.count == 1 ? key.uppercased() : key
        return glyph
    }

    /// The config-file word form the writer emits (`cmd+shift+g`) — modifiers in the
    /// repo's order (cmd, shift, opt, ctrl) then the key. The inverse of `parse`, mirroring
    /// `displayGlyph`'s glyph form.
    var configToken: String {
        var token = ""
        if command { token += "cmd+" }
        if shift { token += "shift+" }
        if option { token += "opt+" }
        if control { token += "ctrl+" }
        // The plus key can't travel literally — `+` is the token separator, so `cmd+shift++`
        // would parse as a stray empty token. Emit the word `plus`; `parse` maps it back.
        return token + (key == "+" ? "plus" : key)
    }

    /// Build the chord an `NSEvent` represents, for keymap lookup. Mirrors the modifier +
    /// `charactersIgnoringModifiers` reading `KeyInterceptor` used before it went data-driven.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else {
            return nil
        }
        self.init(
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control),
            key: characters)
    }
}
