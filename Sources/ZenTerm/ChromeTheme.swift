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
    /// Multiplier on every fill so a hairline is equally visible in any theme. A theme's foreground
    /// to background separation runs 0.40 to 0.94 across the catalog, so a constant alpha was not a
    /// constant border. Derived per theme in `ChromeThemeDeriver`; see `docs/architecture.md`.
    let fillScale: CGFloat
    /// Readability multiplier on every level. Dark ink on a light theme reads fainter at equal
    /// opacity, and this lifts both rather than only the case that needs it.
    ///
    /// **Check `1 / boost` before raising it**: a level above that threshold clamps to full opacity.
    /// See `docs/architecture.md`.
    static let inkBoost: CGFloat = 1.15

    /// The four weights chrome text and icons are drawn at. **There is no fifth.**
    ///
    /// Every site asks for a level, never a number, so the scale is set once and a new site cannot
    /// invent a weight between two of these. See `docs/architecture.md`.
    enum InkLevel: CaseIterable {
        /// Quieter than the thing it sits beside: a disabled label, a hint under a caption.
        case faint
        /// Recedes: captions, hints, subtitles, counts, placeholders, search glyphs.
        case muted
        /// A control at rest: a toolbar icon, an inactive tab, a chevron.
        case subtle
        /// Active, hovered, or primary.
        case normal

        var alpha: CGFloat {
            switch self {
            case .faint: return 0.35
            case .muted: return 0.5
            case .subtle: return 0.7
            case .normal: return 1
            }
        }
    }

    /// Foreground-toned ink at one of the four weights. Sourced from the theme's foreground, so it
    /// adapts on its own: light on a dark theme, dark on a light one.
    func ink(_ level: InkLevel) -> NSColor {
        foreground.nsColor.withAlphaComponent(min(1, level.alpha * Self.inkBoost))
    }

    /// The three weights an interactive fill is drawn at, in declaration order.
    ///
    /// **The ordering is guaranteed here**, not re-tuned per control: all three go through the same
    /// `fillScale`, so no theme can pull one above another. Seven hand-tuned hover values is what
    /// the alternative produced. See `docs/architecture.md`.
    enum FillLevel: CaseIterable {
        /// A filled surface at rest: a keycap, a progress track, an unfocused field.
        case rest
        /// The pointer is over it.
        case hover
        /// Selected, on, focused, or recording. Accent-toned, and always paired with accent ink or
        /// an accent ring: the fill alone is too faint to carry the state.
        case active

        var alpha: CGFloat {
            switch self {
            case .rest: return 0.06
            case .hover: return 0.10
            case .active: return 0.15
            }
        }
    }

    /// A control's fill at one of the three interactive weights. The tier a control asks for, never
    /// a number, which is what stops its states inverting on a narrow-separation theme.
    func fill(_ level: FillLevel) -> NSColor {
        fill(level == .active ? accent : nil, alpha: level.alpha)
    }

    /// The quiet tier, for a mark with length to carry it: a card edge, a full-width divider, an
    /// idle pane border.
    static let hairline: CGFloat = 0.08
    /// The standard tier: a control's border at rest, and any short mark that reads faint at
    /// `hairline`. The dock's 1x12 group ticks are the latter — a 12pt rule and a 400pt one do not
    /// read alike at equal alpha, because the eye integrates over the mark's area.
    static let border: CGFloat = 0.10
    /// The ring around a colour swatch. Heavier than `border` because it has to contain an
    /// *arbitrary* colour rather than sit on the theme background: a dark theme's black slot
    /// vanishes against the list card without it.
    static let swatchRing: CGFloat = 0.15

    /// A **structural fill**: a hairline, a divider, a border. Takes a raw alpha because nothing
    /// about a divider can invert, but pass one of the three constants above rather than a literal
    /// so the same number cannot mean three things. Named apart from `ink(_:)` so the fill path
    /// cannot colour text.
    ///
    /// **Pass a role colour as `tint` rather than applying alpha to it yourself**, or that fill
    /// escapes `fillScale` and stops being comparable to the others in the same control.
    func fill(_ tint: TerminalColor? = nil, alpha: CGFloat) -> NSColor {
        (tint ?? foreground).nsColor.withAlphaComponent(min(1, alpha * Self.inkBoost * fillScale))
    }

    /// The accent square behind an icon glyph on a floating card: a toast, the update card, the
    /// keybind hint bubble. One value, or three cards carry the same badge at three weights.
    static let badgeTint: CGFloat = 0.15
    /// A selected row, and the focus fill inputs share with it. Heavier than a badge because it
    /// spans a whole row rather than backing a single glyph.
    static let selectionTint: CGFloat = 0.18

    /// The selected row in a palette, and the focus fill every input and nav row shares with it.
    /// The most load-bearing fill in the chrome, so it lives here rather than on whichever view
    /// happened to need it first.
    var selectionFill: NSColor { tint(accent, alpha: Self.selectionTint) }

    /// A **standalone** role-toned surface with no sibling fill to stay ordered against: an icon
    /// badge, a selection row, the find bar's own wash, a scrollback selection.
    ///
    /// Deliberately outside `fillScale`. These sit behind text, where the constraint is not to fight
    /// it, and scaling one to 1.77 puts an accent at 0.37 under a caption. Anything that *does* have
    /// a sibling fill takes `fill(_:)` instead, or the pair re-inverts.
    func tint(_ role: TerminalColor, alpha: CGFloat) -> NSColor {
        role.nsColor.withAlphaComponent(min(1, alpha * Self.inkBoost))
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
