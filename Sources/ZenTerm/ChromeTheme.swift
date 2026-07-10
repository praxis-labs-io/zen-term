import AppKit
import TerminalKit

/// The chrome's color roles, derived from the terminal palette. Sized to the roles the
/// chrome actually uses today (backdrop/tab/toast backgrounds, toast title, the
/// info/warning/destructive accent trio, and the accent/attention/muted roles for active
/// UI, the tab "waiting" indicator, and secondary text); grows only when a chrome site
/// needs a new role.
struct ChromeTheme: Equatable {
    let background: TerminalColor
    let foreground: TerminalColor
    let info: TerminalColor
    let warning: TerminalColor
    let destructive: TerminalColor
    let accent: TerminalColor
    let attention: TerminalColor
    let muted: TerminalColor

    /// A foreground-toned chrome ink at a given opacity — icon tints, text, hairlines, and
    /// hover fills. Sourced from the theme's foreground so it adapts automatically: light on a
    /// dark theme, dark on a light one. `alpha` is the site's existing opacity, kept 1-for-1.
    func ink(alpha: CGFloat) -> NSColor {
        foreground.nsColor.withAlphaComponent(alpha)
    }
}
