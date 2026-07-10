import AppKit

/// A declarative ephemeral command float. Everything variable about a float lives here;
/// the tool-float engine on `TabController` does the rest. Floats are user-defined in
/// `~/.config/zen-term/config` (`float = …` lines); the `toggle` chord is their single
/// source of truth, driving both the keybinding and the palette glyph.
struct ToolFloat: Equatable {
    let id: String  // stable id, e.g. "gitdash"
    let title: String  // command-palette title, e.g. "Open GitDash"
    let icon: String  // dock icon: an SF Symbol name, or a bundled brand mark ("github", "git")
    let command: String  // runs as `$SHELL -l -i -c command` at the focused pane's cwd
    let widthFraction: CGFloat
    let heightFraction: CGFloat
    let requiresGitRepo: Bool
    let emptyGuard: EmptyGuard?
    let toggle: Chord  // the config `key:` — binds the chord AND renders the palette glyph

    /// Palette glyph string, e.g. "⌘⇧G" — derived from `toggle`, never authored separately.
    var shortcut: String { toggle.displayGlyph }
}

/// A pre-open probe: `probe` runs at the focused cwd; if it exits 0 (nothing to show), the
/// float doesn't open and `toast` is surfaced instead. The probe runs in a plain,
/// **non-login/non-interactive** shell (`$SHELL -c`) so it doesn't pay rc-sourcing latency —
/// so its command must be on the default `PATH`, not only wired up by a login/`.zshrc` — and
/// is bounded by a short timeout, failing open (the float opens) on timeout or error.
struct EmptyGuard: Equatable {
    let probe: String
    let toast: ToastContent
}

/// The active tool floats — the ones the user declared in their config. There are no
/// built-in floats: with no config the list is empty and the dock shows no float buttons.
/// The dock button, palette entry, git guard, and toggle behavior all derive from a spec.
enum ToolFloatCatalog {
    static var all: [ToolFloat] { GeneralConfig.current.floats }

    static func byID(_ id: String) -> ToolFloat? { all.first { $0.id == id } }
}
