import AppKit

enum FloatShadow {
    enum Tier: CaseIterable {
        case overlay
        case float
        case modal

        var darkening: CGFloat {
            switch self {
            case .overlay: return 7
            case .float: return 12
            case .modal: return 18
            }
        }

        /// Dark themes cannot show the target darkening without a heavy halo; the 1pt edge carries their depth.
        var maxAlpha: CGFloat {
            switch self {
            case .overlay: return 0.18
            case .float: return 0.30
            case .modal: return 0.38
            }
        }

        var blur: CGFloat {
            switch self {
            case .overlay: return 4
            case .float: return 8
            case .modal: return 12
            }
        }

        var offset: NSSize {
            switch self {
            case .overlay: return NSSize(width: 0, height: -2)
            case .float: return NSSize(width: 0, height: -3)
            case .modal: return NSSize(width: 0, height: -4)
            }
        }

        /// `CGContext` blur renders at half the `NSShadow` scale.
        var contextBlur: CGFloat { blur * 2 }
    }

    static var edge: NSColor { Theme.current.chrome.fill(alpha: ChromeTheme.hairline) }

    /// Black is theme-independent; its strength is solved per theme.
    static func color(_ tier: Tier) -> NSColor {
        NSColor.black.withAlphaComponent(Theme.current.chrome.shadowAlpha(tier))
    }

    /// Set via `NSView.shadow`: subtree insertion zeroes `layer.shadow*`.
    static func apply(_ tier: Tier, to view: NSView) {
        view.layer?.masksToBounds = false
        let shadow = NSShadow()
        shadow.shadowColor = color(tier)
        shadow.shadowBlurRadius = tier.blur
        shadow.shadowOffset = tier.offset
        view.shadow = shadow
    }
}
