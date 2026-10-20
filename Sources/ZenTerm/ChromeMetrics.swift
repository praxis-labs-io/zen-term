import AppKit

enum ChromeMetrics {
    static var panelGap: CGFloat { GeneralConfig.current.panelGap }
    static var windowGutter: CGFloat { GeneralConfig.current.windowGutter }

    /// The standard macOS titlebar height.
    private static let trafficLightClearance: CGFloat = 28

    // Fixed, not the gutter: the dock's buttons overhang the tab bar, so a gutter of 0 would collide.
    static let footerGap = Spacing.s8

    static var topInset: CGFloat {
        windowGutter + (GeneralConfig.current.windowChrome ? trafficLightClearance : 0)
    }

    enum Spacing {
        static let s2: CGFloat = 2
        static let s4: CGFloat = 4
        static let s6: CGFloat = 6
        static let s8: CGFloat = 8
        static let s10: CGFloat = 10
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s20: CGFloat = 20
        static let controlInset = s10
        static let modalSectionGap = s12
        static let modalInsets = NSEdgeInsets(top: s16, left: s20, bottom: s16, right: s20)
    }

    enum Height {
        static let xs: CGFloat = 20
        static let sm: CGFloat = 24
        static let control: CGFloat = 28
        static let lg: CGFloat = 32
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
