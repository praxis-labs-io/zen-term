import AppKit
import TerminalKit

/// The chrome's color roles, derived from the terminal palette. Sized to the roles the
/// chrome actually uses today (backdrop/tab/toast backgrounds, toast title, the
/// info/warning/destructive accent trio, and the accent/attention/muted roles for active
/// UI, the tab "waiting" indicator, and secondary text); grows only when a chrome site
/// needs a new role.
struct ChromeTheme: Equatable {
    let background: TerminalColor
    /// A chrome surface sitting **on** the background, one step up from it (ZEN-324).
    ///
    /// A card or a toast floats over a terminal, so `background` is enough to separate it. A
    /// surface inside a pane does not have that luxury: the pane's own fill is already
    /// `background`, so anything painted at it disappears. This is the opaque step above, near
    /// enough to read as the same surface and far enough to have an edge. `ink(alpha:)` is the
    /// wrong tool for it, being translucent, so the terminal's own text shows through.
    let elevated: TerminalColor
    let foreground: TerminalColor
    let info: TerminalColor
    let warning: TerminalColor
    let destructive: TerminalColor
    let accent: TerminalColor
    let attention: TerminalColor
    let muted: TerminalColor
    /// Green "added / success" role — the only ANSI hue the chrome hadn't needed until the diff
    /// viewer's added-line fg/bg (ZEN-226). Named for meaning, not hue, like the other roles.
    let positive: TerminalColor

    /// Syntax-highlighting roles for the diff viewer (ZEN-238), resolved via `SyntaxRole`. Named
    /// for token meaning, not hue, and derived from the ANSI-16 set so a bring-your-own theme
    /// recolors them; `synComment` is a faint fg/bg blend (like `muted`) rather than an ANSI slot.
    let synKeyword: TerminalColor
    let synString: TerminalColor
    let synComment: TerminalColor
    let synNumber: TerminalColor
    let synType: TerminalColor
    let synFunction: TerminalColor
    let synPunctuation: TerminalColor

    /// Readability multiplier applied to every ink opacity. The chrome's per-site opacities
    /// were tuned for light-on-dark; a dark ink at the same opacity on a light theme reads
    /// fainter, so we lift them all. Applied in both modes (a small lift helps dark's faint
    /// secondary text too). Tune here — it's the single knob for chrome ink contrast.
    static let inkBoost: CGFloat = 1.3

    /// A foreground-toned chrome ink at a given opacity — icon tints, text, hairlines, and
    /// hover fills. Sourced from the theme's foreground so it adapts automatically (light on a
    /// dark theme, dark on a light one), lifted by `inkBoost` for readability.
    func ink(alpha: CGFloat) -> NSColor {
        foreground.nsColor.withAlphaComponent(min(1, alpha * Self.inkBoost))
    }
}
