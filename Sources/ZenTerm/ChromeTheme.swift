import AppKit
import TerminalKit

struct ChromeTheme: Equatable {
    let background: TerminalColor
    let foreground: TerminalColor
    let info: TerminalColor
    let warning: TerminalColor
    let destructive: TerminalColor
    let accent: TerminalColor
    let attention: TerminalColor
    let muted: TerminalColor
    let positive: TerminalColor
    /// Per theme: foreground to background separation runs 0.40 to 0.94, so a constant alpha is not a constant border.
    let fillScale: CGFloat
    /// Check `1 / inkBoost` before raising it: above that a level clamps to opaque.
    static let inkBoost: CGFloat = 1.15

    enum InkLevel: CaseIterable {
        case faint
        case muted
        case subtle
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

    func ink(_ level: InkLevel) -> NSColor {
        foreground.nsColor.withAlphaComponent(min(1, level.alpha * Self.inkBoost))
    }

    enum FillLevel: CaseIterable {
        case rest
        case hover
        case active

        var alpha: CGFloat {
            switch self {
            case .rest: return 0.06
            case .hover: return 0.10
            case .active: return 0.15
            }
        }
    }

    func fill(_ level: FillLevel) -> NSColor {
        fill(level == .active ? accent : nil, alpha: level.alpha)
    }

    static let hairline: CGFloat = 0.08
    static let border: CGFloat = 0.10
    /// Heavier than `border`: it has to contain an arbitrary color, and a black slot vanishes on the list card.
    static let swatchRing: CGFloat = 0.15

    func fill(_ tint: TerminalColor? = nil, alpha: CGFloat) -> NSColor {
        (tint ?? foreground).nsColor.withAlphaComponent(min(1, alpha * Self.inkBoost * fillScale))
    }

    static let badgeTint: CGFloat = 0.15
    static let selectionTint: CGFloat = 0.18

    var selectionFill: NSColor { tint(accent, alpha: Self.selectionTint) }

    /// Outside `fillScale` because these sit behind text; anything with a sibling fill takes `fill(_:)`, or the pair inverts.
    func tint(_ role: TerminalColor, alpha: CGFloat) -> NSColor {
        role.nsColor.withAlphaComponent(min(1, alpha * Self.inkBoost))
    }

    /// Below `background-alpha` 1 a pane has no fill of its own, so a bare tint would blend with the desktop.
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
    /// AppKit defaults the caret to the macOS accent, and the field editor is shared per window, so call on every focus.
    func applyThemedCaret() {
        (currentEditor() as? NSTextView)?.insertionPointColor = Theme.current.chrome.foreground.nsColor
    }
}
