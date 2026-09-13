import Foundation

/// Non-appearance terminal settings from user config.
public struct TerminalBehavior: Equatable, Sendable {
    public enum CursorStyle: Sendable, Equatable { case block, bar, underline }

    public var cursorStyle: CursorStyle
    public var cursorBlink: Bool
    /// Pixels, for bar and underline cursors. Defaults to 2 because ghostty's 1px base is faint on Retina.
    public var cursorThickness: Int
    public var optionAsAlt: Bool
    /// Off by default: ghostty's thickening is at full strength and reads as permanent bold on Retina.
    public var fontThicken: Bool
    public var scrollMultiplier: Double
    /// Absolute path to one GLSL cursor shader, or nil.
    public var cursorShader: String?
    /// Terminal background opacity, 0 to 1. Below 1 the chrome shows through.
    public var backgroundAlpha: Double

    public init(
        cursorStyle: CursorStyle = .block,
        cursorBlink: Bool = true,
        cursorThickness: Int = 2,
        optionAsAlt: Bool = true,
        fontThicken: Bool = false,
        scrollMultiplier: Double = 1.5,
        cursorShader: String? = nil,
        backgroundAlpha: Double = 1
    ) {
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.cursorThickness = cursorThickness
        self.optionAsAlt = optionAsAlt
        self.fontThicken = fontThicken
        self.scrollMultiplier = scrollMultiplier
        self.cursorShader = cursorShader
        self.backgroundAlpha = backgroundAlpha
    }

    public var isBackgroundSolid: Bool { backgroundAlpha >= 1 }

    public static let `default` = TerminalBehavior()

    public var ghosttyCursorStyle: String {
        switch cursorStyle {
        case .block: return "block"
        case .bar: return "bar"
        case .underline: return "underline"
        }
    }

    /// ghostty's `adjust-cursor-thickness` over its 1px base, or nil when none is needed.
    public var ghosttyCursorThicknessDelta: Int? {
        cursorThickness > 1 ? cursorThickness - 1 : nil
    }

    /// ghostty's `background-opacity`, or nil at full opacity.
    public var ghosttyBackgroundOpacity: Double? {
        isBackgroundSolid ? nil : backgroundAlpha
    }
}
