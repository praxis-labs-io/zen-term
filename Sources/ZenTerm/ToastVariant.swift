import AppKit
import TerminalKit

/// A toast's tone. Drives only the icon badge + accent color; the card's background,
/// hairline border, and drop shadow stay the shared overlay-card chrome (`FloatShadow`),
/// identical across variants: the icon and action buttons carry the tone, so the border
/// stays neutral. Accents come from the chrome theme (foam/gold/love under the Rosé Pine
/// default).
enum ToastVariant: Equatable {
    case info, positive, warning, destructive

    /// The chrome role this tone reads from. The badge needs the role itself, not a resolved
    /// colour, so it can go through `chrome.tint(_:alpha:)` rather than applying alpha by hand.
    func role(in chrome: ChromeTheme) -> TerminalColor {
        switch self {
        case .info: return chrome.info
        case .positive: return chrome.positive
        case .warning: return chrome.warning
        case .destructive: return chrome.destructive
        }
    }

    /// The accent — tints the icon and the badge fill. Defined in terms of `role(in:)` so the two
    /// cannot drift: painting the badge from `chrome.accent` instead flattened every variant.
    var accent: NSColor { role(in: Theme.current.chrome).nsColor }

    /// The default badge glyph (an SF Symbol); a `ToastContent.icon` override wins when set.
    var defaultIcon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .positive: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .destructive: return "xmark.octagon.fill"
        }
    }
}
