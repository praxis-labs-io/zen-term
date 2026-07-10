import CoreGraphics

/// The window a web pane renders in. `fill` uses the whole pane; the rest lock the
/// window to a real device's portrait/landscape dimensions (aspect-correct, centered,
/// scaled to fit) so you can preview a layout at that form factor.
public enum DevicePreset: CaseIterable, Sendable {
    case fill
    case desktop
    case macbook14
    case ipad
    case iphone

    /// The CSS-point size the web view window is constrained to, or nil to fill the pane.
    /// Constants are spike values.
    public var size: CGSize? {
        switch self {
        case .fill: return nil
        case .desktop: return CGSize(width: 1920, height: 1080)  // 1080p display
        case .macbook14: return CGSize(width: 1512, height: 982)  // MacBook Pro 14"
        case .ipad: return CGSize(width: 820, height: 1180)  // iPad (10.9")
        case .iphone: return CGSize(width: 390, height: 844)  // iPhone (12–14)
        }
    }

    /// SF Symbol for the chrome's device switch.
    public var symbol: String {
        switch self {
        case .fill: return "macwindow"
        case .desktop: return "display"
        case .macbook14: return "laptopcomputer"
        case .ipad: return "ipad"
        case .iphone: return "iphone"
        }
    }

    public var label: String {
        switch self {
        case .fill: return "Fill"
        case .desktop: return "Desktop"
        case .macbook14: return "MacBook 14"
        case .ipad: return "iPad"
        case .iphone: return "iPhone"
        }
    }
}
