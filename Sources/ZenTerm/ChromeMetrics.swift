import CoreGraphics

enum ChromeMetrics {
    static var panelGap: CGFloat { GeneralConfig.current.panelGap }
    static var windowGutter: CGFloat { GeneralConfig.current.windowGutter }

    /// The standard macOS titlebar height.
    private static let trafficLightClearance: CGFloat = 28

    static var topInset: CGFloat {
        windowGutter + (GeneralConfig.current.windowChrome ? trafficLightClearance : 0)
    }
}
