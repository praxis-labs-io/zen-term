import CoreGraphics

/// A visual scale applied to the web preview — independent of the device width. It
/// shrinks the rendered page (no reflow) so a wide desktop layout can fit a narrow
/// pane, e.g. a full "desktop view" with both drawers open. `.fit` auto-scales the
/// device width down to the pane (never upscales); the percents are fixed steps.
public enum WebZoom: Sendable, Equatable {
    case fit
    case percent(Int)

    public static let presets: [WebZoom] = [
        .fit, .percent(100), .percent(75), .percent(50), .percent(33), .percent(25),
    ]

    public var label: String {
        switch self {
        case .fit: return "Fit"
        case .percent(let p): return "\(p)%"
        }
    }

    /// The scale factor for a pane of `paneWidth` showing content laid out at `contentWidth`.
    public func scale(paneWidth: CGFloat, contentWidth: CGFloat) -> CGFloat {
        switch self {
        case .fit:
            guard contentWidth > 0 else { return 1 }
            return min(1, paneWidth / contentWidth)
        case .percent(let p):
            return CGFloat(p) / 100
        }
    }
}
