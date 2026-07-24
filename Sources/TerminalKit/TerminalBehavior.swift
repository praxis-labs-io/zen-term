import Foundation

/// Backend-neutral terminal behavior the chrome dials from user config — the seam's
/// vocabulary for the non-appearance knobs (cursor shape/thickness, Option semantics, scroll
/// feel, custom render shaders). The libghostty backend maps the cursor, Option, and shader
/// fields to ghostty config; the scroll multiplier is applied in `GhosttyHostView`'s own
/// scroll handling, not via config.
public struct TerminalBehavior: Equatable, Sendable {
    public enum CursorStyle: Sendable, Equatable { case block, bar, underline }

    public var cursorStyle: CursorStyle
    public var cursorBlink: Bool
    /// Cursor thickness in pixels, for the bar/underline styles (block fills the cell, so it's
    /// unaffected). ghostty's base is 1px — nearly invisible on Retina — so the default is 2.
    public var cursorThickness: Int
    public var optionAsAlt: Bool
    public var scrollMultiplier: Double
    /// Absolute path to a single GLSL cursor shader (a post-process pass), or nil for none. The
    /// chrome resolves a bundled shader name to this path before it crosses the seam; the backend
    /// emits it to ghostty config. Single by design — the chrome ships one selectable effect,
    /// not a stack.
    public var cursorShader: String?

    public init(
        cursorStyle: CursorStyle = .block,
        cursorBlink: Bool = true,
        cursorThickness: Int = 2,
        optionAsAlt: Bool = true,
        scrollMultiplier: Double = 1.5,
        cursorShader: String? = nil
    ) {
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.cursorThickness = cursorThickness
        self.optionAsAlt = optionAsAlt
        self.scrollMultiplier = scrollMultiplier
        self.cursorShader = cursorShader
    }

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
}
