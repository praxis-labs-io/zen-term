import TerminalKit

/// Maps a `TerminalTheme` to `ChromeTheme` roles. The accent slots are the exact ANSI
/// colors the chrome used to hardcode by hand (Rosé Pine foam/gold/love/iris/rose in
/// `ToastVariant` and the tab bar), so any ghostty theme recolors the chrome consistently.
enum ChromeThemeDeriver {
    /// `accent` is the one role the user can repoint (`accent-color`, ZEN-255) — it is the chrome's
    /// primary and reaches every focus and active surface. Nil keeps `AccentSlot.themeDefault`, so
    /// an unset key derives exactly what it always has. The other roles stay fixed: they are read as
    /// meanings (a warning is not a taste), and `info`/`warning`/`destructive` in particular have to
    /// stay distinguishable from each other whatever the primary becomes.
    static func derive(from terminal: TerminalTheme, accent: AccentSlot? = nil) -> ChromeTheme {
        func slot(_ index: Int) -> TerminalColor {
            terminal.ansi.indices.contains(index) ? terminal.ansi[index] : terminal.foreground
        }
        return ChromeTheme(
            background: terminal.background,
            foreground: terminal.foreground,
            info: slot(4),
            warning: slot(3),
            destructive: slot(1),
            accent: (accent ?? .themeDefault).color(in: terminal),
            attention: slot(6),
            muted: blend(terminal.foreground, terminal.background, 0.55))
    }

    /// A per-channel weighted average of `a` and `b` at `t` (`t` = 1 keeps `a`, `t` = 0 keeps
    /// `b`), rounded to the nearest 8-bit value. Used to derive `muted` from the foreground/
    /// background pair rather than reproducing a palette color that has no ANSI slot.
    private static func blend(_ a: TerminalColor, _ b: TerminalColor, _ t: Double) -> TerminalColor {
        func mix(_ ca: UInt8, _ cb: UInt8) -> UInt8 {
            UInt8((Double(ca) * t + Double(cb) * (1 - t)).rounded())
        }
        return TerminalColor(
            red: mix(a.red, b.red),
            green: mix(a.green, b.green),
            blue: mix(a.blue, b.blue))
    }
}
