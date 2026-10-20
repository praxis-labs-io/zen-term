import CoreGraphics

enum ChromeMetrics {
    static var panelGap: CGFloat { GeneralConfig.current.panelGap }
    static var windowGutter: CGFloat { GeneralConfig.current.windowGutter }

    /// The standard macOS titlebar height.
    private static let trafficLightClearance: CGFloat = 28

    // Fixed, not the gutter: the dock's buttons overhang the tab bar, so a gutter of 0 would collide.
    static let footerGap: CGFloat = 8

    static var topInset: CGFloat {
        windowGutter + (GeneralConfig.current.windowChrome ? trafficLightClearance : 0)
    }

    enum Radius {
        static let control: CGFloat = 6
        static let surface: CGFloat = 8

        static func capsule(_ height: CGFloat) -> CGFloat { height / 2 }
    }

    enum Border {
        static let width: CGFloat = 1
    }
}
