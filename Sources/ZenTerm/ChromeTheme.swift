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
    /// Green "added / success" role. Named for meaning, not hue, like the other roles.
    let positive: TerminalColor
    /// The three weights chrome text and icons are drawn at. **There is no fourth.**
    ///
    /// Every site asks for a level, never a number, so the scale is set once here and a new site
    /// cannot invent a weight between two of these. It replaced twenty-one hand-tuned alphas and a
    /// 1.3 multiplier that clamped everything past ~0.77 to full opacity, which made `0.95` and `1`
    /// the same colour and hid the ceiling from anyone tuning a value.
    enum InkLevel {
        /// Recedes: captions, hints, subtitles, counts, placeholders, search glyphs.
        case muted
        /// A control at rest: a toolbar icon, an inactive tab, a chevron.
        case subtle
        /// Active, hovered, or primary.
        case normal

        var alpha: CGFloat {
            switch self {
            case .muted: return 0.5
            case .subtle: return 0.7
            case .normal: return 1
            }
        }
    }

    /// Foreground-toned ink at one of the three weights. Sourced from the theme's foreground, so it
    /// adapts on its own: light on a dark theme, dark on a light one.
    func ink(_ level: InkLevel) -> NSColor {
        foreground.nsColor.withAlphaComponent(level.alpha)
    }

    /// A foreground-toned **fill**: a hover wash, a hairline, a divider, a border. Not for text or
    /// icons, which take one of the three levels above — these run an order of magnitude fainter
    /// (0.04 to 0.16) and a shared scale would either wash them out or make them read as content.
    func ink(alpha: CGFloat) -> NSColor {
        foreground.nsColor.withAlphaComponent(alpha)
    }

    /// `tint` composited over `base`, source-over. A chrome surface inside a pane paints its tint on
    /// the pane's own resolved fill rather than on its own: the tints are alpha inks tuned for an
    /// opaque background, and below `background-alpha` a pane has none, so a bare tint blends with
    /// whatever is behind the window and reads grey. Compositing keeps the surface at the
    /// pane's alpha, so it agrees with the padding ring instead of the desktop.
    static func surface(tint: NSColor, over base: NSColor) -> NSColor {
        guard let top = tint.usingColorSpace(.sRGB), let bottom = base.usingColorSpace(.sRGB) else {
            return tint
        }
        let ta = top.alphaComponent
        let ba = bottom.alphaComponent
        let alpha = ta + ba * (1 - ta)
        guard alpha > 0 else { return .clear }
        func channel(_ t: CGFloat, _ b: CGFloat) -> CGFloat { (t * ta + b * ba * (1 - ta)) / alpha }
        return NSColor(
            srgbRed: channel(top.redComponent, bottom.redComponent),
            green: channel(top.greenComponent, bottom.greenComponent),
            blue: channel(top.blueComponent, bottom.blueComponent),
            alpha: alpha)
    }
}

extension NSTextField {
    /// Paint this field's caret from the theme. AppKit leaves an `NSTextField`'s insertion point at the
    /// *macOS system accent*, which follows the OS setting rather than `Theme.current`, so a system
    /// accent with no place in the theme blinks in every field. The colors rule reaching the one
    /// spot a color is never assigned. `NSTextView` takes `insertionPointColor` and needs none of
    /// this.
    ///
    /// Called each time a field takes focus, not once at build: the field editor is shared per window
    /// and re-tinted when it moves between fields.
    func applyThemedCaret() {
        (currentEditor() as? NSTextView)?.insertionPointColor = Theme.current.chrome.foreground.nsColor
    }
}
