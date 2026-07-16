import AppKit

/// A declarative command float whose process lifetime is set by `persist:`. Everything variable
/// about a float lives here; the tool-float engine on `TabController` does the rest. Floats are
/// user-defined in `~/.config/zen-term/config` (`float = …` lines); the `toggle` chord is their
/// single source of truth, driving both the keybinding and the palette glyph.
struct ToolFloat: Equatable {
    let id: String  // stable id, e.g. "gitdash"
    let title: String  // command-palette title, e.g. "Open GitDash"
    let icon: String  // dock icon: an SF Symbol name, or a bundled brand mark ("github", "git")
    let command: String  // runs as `$SHELL -l -i -c command` at the focused pane's cwd
    let widthFraction: CGFloat
    let heightFraction: CGFloat
    let requiresGitRepo: Bool

    /// How long a float's process lives, and where the live instance is kept. Scope only exists
    /// when a float persists — an ephemeral tool spawns fresh at the focused cwd every open, so it
    /// has no instance to scope. The raw value is the config token; the case names avoid colliding
    /// with `Optional.none` (`.none`) and with the `dir:` field.
    enum Persistence: String {
        /// Terminate on dismiss; fresh spawn every open. Right for anything whose state goes stale
        /// (a file explorer, a scratch shell).
        case ephemeral = "none"
        /// One live instance per directory identity, per tab — reopening in the same directory
        /// restores it; a different one discards and respawns. Right for directory-bound tools.
        case directory = "dir"
        /// One live instance per tab, anchored at first-open cwd. Never re-anchors.
        case tab
    }

    let persist: Persistence
    let toggle: Chord  // the config `key:` — binds the chord AND renders the palette glyph

    /// Palette glyph string, e.g. "⌘⇧G" — derived from `toggle`, never authored separately.
    var shortcut: String { toggle.displayGlyph }
}

/// The active tool floats — the ones the user declared in their config. There are no
/// built-in floats: with no config the list is empty and the dock shows no float buttons.
/// The dock button, palette entry, git guard, and toggle behavior all derive from a spec.
enum ToolFloatCatalog {
    static var all: [ToolFloat] { GeneralConfig.current.floats }

    static func byID(_ id: String) -> ToolFloat? { all.first { $0.id == id } }
}
