import Foundation

/// Backend-neutral terminal behavior the chrome dials from user config — the seam's
/// vocabulary for the non-appearance knobs (cursor shape/thickness, Option semantics, glyph
/// thickening, scroll feel, custom render shaders). The libghostty backend maps the cursor,
/// Option, thickening, and shader fields to ghostty config; the scroll multiplier is applied in
/// `GhosttyHostView`'s own scroll handling, not via config.
public struct TerminalBehavior: Equatable, Sendable {
    public enum CursorStyle: Sendable, Equatable { case block, bar, underline }

    public var cursorStyle: CursorStyle
    public var cursorBlink: Bool
    /// Cursor thickness in pixels, for the bar/underline styles (block fills the cell, so it's
    /// unaffected). ghostty's base is 1px — nearly invisible on Retina — so the default is 2.
    public var cursorThickness: Int
    public var optionAsAlt: Bool
    /// Fake-bold every glyph by dilating its coverage. Off by default, matching stock ghostty:
    /// its thickening strength is maxed out, so on a Retina panel it reads as a permanent bold
    /// rather than a nudge.
    public var fontThicken: Bool
    public var scrollMultiplier: Double
    /// Absolute path to a single GLSL cursor shader (a post-process pass), or nil for none. The
    /// chrome resolves a bundled shader name to this path before it crosses the seam; the backend
    /// emits it to ghostty config. Single by design — the chrome ships one selectable effect,
    /// not a stack.
    public var cursorShader: String?
    /// Translucency of the terminal background, 0…1. 1 (the default) is a solid surface; below
    /// that the backend renders its background with alpha and the chrome shows through. The
    /// backend also has to stop asserting opacity to the compositor at that point — see
    /// `GhosttySurface`, where an opaque layer would discard the alpha outright.
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

    /// Whether the surface composites as a solid one — the fast path, and what every layer
    /// standing between the terminal and the window backdrop keys off.
    public var isBackgroundSolid: Bool { backgroundAlpha >= 1 }

    /// The shipped baseline used when no config is present.
    public static let `default` = TerminalBehavior()

    /// ghostty's `cursor-style` token for this shape.
    public var ghosttyCursorStyle: String {
        switch cursorStyle {
        case .block: return "block"
        case .bar: return "bar"
        case .underline: return "underline"
        }
    }

    /// ghostty's `adjust-cursor-thickness` delta (its base thickness is 1px), or nil when no
    /// adjustment is needed so the generated config stays clean.
    public var ghosttyCursorThicknessDelta: Int? {
        cursorThickness > 1 ? cursorThickness - 1 : nil
    }

    /// ghostty's `background-opacity`, or nil at full opacity so the generated config stays
    /// clean and the shipped baseline is unchanged.
    public var ghosttyBackgroundOpacity: Double? {
        isBackgroundSolid ? nil : backgroundAlpha
    }
}
