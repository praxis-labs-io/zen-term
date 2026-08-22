import CoreGraphics
import Foundation
import TerminalKit

/// Value ↔ config-string helpers for the Layout & Motion settings section: render a scalar to the
/// minimal decimal form the `config` file uses, parse+range-validate a typed field, and map the
/// `reduce-motion` enum and `shell-args` list to/from their string forms.
enum LayoutFormat {
    /// Minimal-decimal string (`0.82`, `8`, `0.7`) — `%g` uses the C locale (period) and drops
    /// trailing zeros, matching how the file is hand-written and re-parsed.
    static func number(_ value: CGFloat) -> String { String(format: "%g", Double(value)) }

    /// Parse a numeric field, returning the value only when it's a number inside `range`.
    static func parseNumber(_ text: String, in range: ClosedRange<CGFloat>) -> CGFloat? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let n = Double(trimmed) else { return nil }
        let value = CGFloat(n)
        return range.contains(value) ? value : nil
    }

    static func reduceMotionToken(_ r: GeneralConfig.ReduceMotion) -> String {
        switch r {
        case .system: return "system"
        case .on: return "on"
        case .off: return "off"
        }
    }

    /// The `attention-toast` / `completion-toast` token for whether a notification card waits.
    static func toastDismissalToken(_ dismissal: GeneralConfig.ToastDismissal) -> String {
        switch dismissal {
        case .sticky: return "sticky"
        case .auto: return "auto"
        }
    }

    static func joinArgs(_ args: [String]) -> String { args.joined(separator: " ") }

    static func splitArgs(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// ghostty's `cursor-style` literal for a cursor shape (`block`/`bar`/`underline`).
    static func cursorStyleToken(_ s: TerminalBehavior.CursorStyle) -> String {
        switch s {
        case .block: return "block"
        case .bar: return "bar"
        case .underline: return "underline"
        }
    }

    /// Parse a `cursor-style` value, case-insensitively; nil if it isn't a known shape.
    static func parseCursorStyle(_ text: String) -> TerminalBehavior.CursorStyle? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "block": return .block
        case "bar": return .bar
        case "underline": return .underline
        default: return nil
        }
    }

    /// The config token for a boolean knob (`cursor-style-blink`, `macos-option-as-alt`).
    static func boolToken(_ on: Bool) -> String { on ? "true" : "false" }

    /// The `hide-toolbar-buttons` value: hidden slugs comma-joined in toolbar order, so the file
    /// reads left-to-right like the toolbar and a given set always serializes the same way.
    static func hideToolbarButtonsToken(_ hidden: Set<ToolbarButton>) -> String {
        ToolbarButton.allCases.filter(hidden.contains).map(\.rawValue).joined(separator: ",")
    }
}
