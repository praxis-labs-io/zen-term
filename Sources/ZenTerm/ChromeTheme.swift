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
    let isDark: Bool

    /// A luminance-adaptive grayscale ink. On a dark theme it returns exactly
    /// NSColor(white:alpha:) as before (so dark themes are unchanged); on a light theme it
    /// flips the grayscale value (1 - white) so the same element reads dark-on-light.
    func ink(_ white: CGFloat, alpha: CGFloat) -> NSColor {
        NSColor(white: isDark ? white : 1 - white, alpha: alpha)
    }
}
