import CoreGraphics

/// Shared chrome spacing so the pane-split gutter, the inter-panel (drawer) gap, and the
/// window edge inset stay in sync — tune each in one place.
enum ChromeMetrics {
    /// Gap between tiled panes/panels — both pane splits and the canvas↔drawer seams.
    /// User-overridable via `pane-gap` in `~/.config/zen-term/config`.
    static var panelGap: CGFloat { GeneralConfig.current.panelGap }
    /// Inset from the window edge to the tile region on the leading, trailing, and bottom sides.
    /// User-overridable via `window-gutter` in `~/.config/zen-term/config`.
    static var windowGutter: CGFloat { GeneralConfig.current.windowGutter }

    /// Extra top clearance for the macOS traffic lights, added to `windowGutter` when window chrome
    /// is shown. 28pt is the standard titlebar height; with the default 8pt gutter this restores the
    /// earlier 36pt top inset. `window-chrome = false` drops it back to an even gutter all round.
    private static let trafficLightClearance: CGFloat = 28

    /// Inset from the window's top edge to the tile region: `windowGutter` plus traffic-light
    /// clearance when `window-chrome` is on, so content doesn't sit under the buttons.
    static var topInset: CGFloat {
        windowGutter + (GeneralConfig.current.windowChrome ? trafficLightClearance : 0)
    }
}
