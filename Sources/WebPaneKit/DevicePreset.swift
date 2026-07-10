import CoreGraphics

/// The viewport a web pane renders at. Non-desktop presets constrain the web
/// view's actual width (no zoom) so the page's responsive CSS reflows exactly as
/// it would on that device.
public enum DevicePreset: CaseIterable, Sendable {
    case desktop
    case tablet
    case phone

    /// The CSS-point width to constrain the web view to, or nil for full width.
    /// Widths are spike constants; configurability is future work.
    public var width: CGFloat? {
        switch self {
        case .desktop: return nil
        case .tablet: return 820
        case .phone: return 390
        }
    }
}
