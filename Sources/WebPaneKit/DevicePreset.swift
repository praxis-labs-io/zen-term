import CoreGraphics

/// The viewport a web pane renders at. Non-desktop presets constrain the web
/// view's actual width (no zoom) so the page's responsive CSS reflows exactly as
/// it would on that device.
public enum DevicePreset: CaseIterable, Sendable {
    case desktop
    case tablet
    case phone

    /// The CSS-point size the web view window is constrained to (portrait), or nil for
    /// full pane. Tablet/phone use real device dimensions so the window shows the correct
    /// aspect ratio, centered and scaled to fit. Constants are spike values.
    public var size: CGSize? {
        switch self {
        case .desktop: return nil
        case .tablet: return CGSize(width: 820, height: 1180)  // iPad (10.9")
        case .phone: return CGSize(width: 390, height: 844)  // iPhone (12–14)
        }
    }

    /// SF Symbol for the chrome's device switch.
    public var symbol: String {
        switch self {
        case .desktop: return "display"
        case .tablet: return "ipad"
        case .phone: return "iphone"
        }
    }

    public var label: String {
        switch self {
        case .desktop: return "Desktop"
        case .tablet: return "Tablet"
        case .phone: return "Phone"
        }
    }
}
