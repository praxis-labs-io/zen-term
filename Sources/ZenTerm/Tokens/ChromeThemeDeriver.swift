import CoreGraphics
import TerminalKit

enum ChromeThemeDeriver {
    static func derive(from terminal: TerminalTheme, accent: AccentSlot? = nil) -> ChromeTheme {
        let accent = (accent ?? .themeDefault).color(in: terminal)
        return ChromeTheme(
            background: terminal.background,
            foreground: terminal.foreground,
            info: AccentSlot.blue.color(in: terminal),
            warning: AccentSlot.yellow.color(in: terminal),
            destructive: AccentSlot.red.color(in: terminal),
            accent: accent,
            onAccent: onAccent(for: accent, in: terminal),
            attention: AccentSlot.cyan.color(in: terminal),
            positive: AccentSlot.green.color(in: terminal),
            cursor: terminal.cursor,
            fillScale: fillScale(for: terminal),
            overlayShadowAlpha: shadowAlpha(on: terminal.background, tier: .overlay),
            floatShadowAlpha: shadowAlpha(on: terminal.background, tier: .float),
            modalShadowAlpha: shadowAlpha(on: terminal.background, tier: .modal))
    }

    private static func onAccent(for accent: TerminalColor, in terminal: TerminalTheme) -> TerminalColor {
        contrastRatio(terminal.background, accent) >= contrastRatio(terminal.foreground, accent)
            ? terminal.background : terminal.foreground
    }

    static func contrastRatio(_ first: TerminalColor, _ second: TerminalColor) -> Double {
        let (a, b) = (relativeLuminance(of: first), relativeLuminance(of: second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func relativeLuminance(of color: TerminalColor) -> Double {
        relativeLuminance(channels(of: color))
    }

    private static func channels(of color: TerminalColor) -> [Double] {
        [color.red, color.green, color.blue].map(Double.init)
    }

    /// A fixed anchor, not the catalog's median, so adding a theme doesn't re-weight the others.
    private static let referenceSeparation: CGFloat = 0.714

    static func fillScale(for terminal: TerminalTheme) -> CGFloat {
        let separation = abs(perceivedLuminance(terminal.foreground) - perceivedLuminance(terminal.background))
        guard separation > 0.01 else { return 1.8 }
        return min(1.8, max(1, referenceSeparation / separation))
    }

    /// The formula `TerminalColor.isDark` uses, so both read a color the same way.
    private static func perceivedLuminance(_ color: TerminalColor) -> CGFloat {
        0.299 * CGFloat(color.red) / 255 + 0.587 * CGFloat(color.green) / 255
            + 0.114 * CGFloat(color.blue) / 255
    }

    static func shadowAlpha(on background: TerminalColor, tier: FloatShadow.Tier) -> CGFloat {
        let cap = Double(tier.maxAlpha)
        let goal = Double(tier.darkening)
        guard darkening(of: background, alpha: cap) >= goal else { return tier.maxAlpha }
        var low = 0.0
        var high = cap
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if darkening(of: background, alpha: mid) < goal { low = mid } else { high = mid }
        }
        return CGFloat(high)
    }

    private static func darkening(of background: TerminalColor, alpha: Double) -> Double {
        lightness(relativeLuminance(of: background))
            - lightness(relativeLuminance(channels(of: background).map { $0 * (1 - alpha) }))
    }

    private static func relativeLuminance(_ channels: [Double]) -> Double {
        let linear = channels.map { value -> Double in
            let c = value / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private static func lightness(_ luminance: Double) -> Double {
        let f = luminance > 216.0 / 24389 ? cbrt(luminance) : (24389.0 / 27 * luminance + 16) / 116
        return 116 * f - 16
    }

    static func withHighlightColors(_ terminal: TerminalTheme, chrome: ChromeTheme) -> TerminalTheme {
        var theme = terminal
        theme.selectionForeground = terminal.selectionForeground ?? terminal.foreground
        theme.searchForeground = terminal.searchForeground ?? terminal.foreground
        theme.searchBackground =
            terminal.searchBackground ?? blend(chrome.accent, terminal.background, 0.35)
        theme.searchSelectedForeground = terminal.searchSelectedForeground ?? terminal.background
        theme.searchSelectedBackground = terminal.searchSelectedBackground ?? chrome.accent
        return theme
    }

    private static func blend(_ a: TerminalColor, _ b: TerminalColor, _ t: Double) -> TerminalColor {
        func mix(_ ca: UInt8, _ cb: UInt8) -> UInt8 {
            UInt8((Double(ca) * t + Double(cb) * (1 - t)).rounded())
        }
        return TerminalColor(
            red: mix(a.red, b.red),
            green: mix(a.green, b.green),
            blue: mix(a.blue, b.blue))
    }
}
