import CoreGraphics

/// The viewport a web pane renders at. Non-desktop presets constrain the web
/// view's actual width (no zoom) so the page's responsive CSS reflows exactly as
/// it would on that device.
public enum DevicePreset: CaseIterable, Sendable {
    case desktop
    case tablet
    case phone

    /// The CSS-point width the web view window is constrained to (drives responsive
    /// reflow), or nil for full pane width. Widths are spike constants; configurability
    /// is future work.
    public var width: CGFloat? {
        switch self {
        case .desktop: return nil
        case .tablet: return 820
        case .phone: return 390
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
