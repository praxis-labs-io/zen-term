import AppKit

/// A toast's tone. Drives only the icon badge + accent color; the card's background,
/// hairline border, and drop shadow stay the shared overlay-card chrome (`FloatShadow`),
/// identical across variants. Rosé Pine Moon: foam (info), gold (warning), love (destructive).
enum ToastVariant: Equatable {
    case info, warning, destructive

    /// The accent — tints the icon and (at 15% alpha) the badge fill.
    var accent: NSColor {
        switch self {
        case .info: return NSColor(srgbRed: 0x9c / 255, green: 0xcf / 255, blue: 0xd8 / 255, alpha: 1)
        case .warning: return NSColor(srgbRed: 0xf6 / 255, green: 0xc1 / 255, blue: 0x77 / 255, alpha: 1)
        case .destructive: return NSColor(srgbRed: 0xeb / 255, green: 0x6f / 255, blue: 0x92 / 255, alpha: 1)
        }
    }

    /// The card border. Info keeps the neutral overlay-card hairline; warning/destructive
    /// take a tinted edge so the tone reads even before the text does.
    var border: NSColor {
        switch self {
        case .info: return FloatShadow.edge
        case .warning: return accent.withAlphaComponent(0.40)
        case .destructive: return accent.withAlphaComponent(0.50)
        }
    }

    /// The default badge glyph (an SF Symbol); a `ToastContent.icon` override wins when set.
    var defaultIcon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .destructive: return "xmark.octagon.fill"
        }
    }
}
