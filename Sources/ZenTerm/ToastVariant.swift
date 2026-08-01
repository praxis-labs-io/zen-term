import AppKit

/// A toast's tone. Drives only the icon badge + accent color; the card's background,
/// hairline border, and drop shadow stay the shared overlay-card chrome (`FloatShadow`),
/// identical across variants. Accents come from the chrome theme (foam/gold/love under the
/// Rosé Pine default).
enum ToastVariant: Equatable {
    case info, positive, warning, destructive

    /// The accent — tints the icon and (at 15% alpha) the badge fill. Sourced from the
    /// chrome theme so accents follow the active theme (foam/gold/love under Rosé Pine).
    var accent: NSColor {
        switch self {
        case .info: return Theme.current.chrome.info.nsColor
        case .positive: return Theme.current.chrome.positive.nsColor
        case .warning: return Theme.current.chrome.warning.nsColor
        case .destructive: return Theme.current.chrome.destructive.nsColor
        }
    }

    /// The card border. Info keeps the neutral overlay-card hairline; warning/destructive
    /// take a tinted edge so the tone reads even before the text does.
    var border: NSColor {
        switch self {
        case .info: return FloatShadow.edge
        case .positive: return accent.withAlphaComponent(0.40)
        case .warning: return accent.withAlphaComponent(0.40)
        case .destructive: return accent.withAlphaComponent(0.50)
        }
    }

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
