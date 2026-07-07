import CoreGraphics

/// Shared chrome spacing so the pane-split gutter, the inter-panel (drawer) gap, and the
/// window edge inset stay in sync — tune each in one place.
enum ChromeMetrics {
    /// Gap between tiled panes/panels — both pane splits and the canvas↔drawer seams.
    static let panelGap: CGFloat = 8
    /// Inset from the window edge to the tile region (leading, trailing, bottom).
    static let windowGutter: CGFloat = 8
    /// Top inset clearing the window's traffic lights (`.fullSizeContentView`).
    static let topInset: CGFloat = 36
}
