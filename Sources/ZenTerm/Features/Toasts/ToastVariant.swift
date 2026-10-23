import TerminalKit

enum ToastVariant: Equatable {
    case info, positive, warning, destructive

    /// Returns the role, not a resolved color, so the badge can go through `chrome.tint(_:alpha:)`.
    func role(in chrome: ChromeTheme) -> TerminalColor {
        switch self {
        case .info: return chrome.info
        case .positive: return chrome.positive
        case .warning: return chrome.warning
        case .destructive: return chrome.destructive
        }
    }

    var defaultIcon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .positive: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .destructive: return "xmark.octagon.fill"
        }
    }
}
