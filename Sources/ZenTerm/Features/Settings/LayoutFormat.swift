import CoreGraphics
import Foundation
import TerminalKit

enum LayoutFormat {
    /// `%g` uses the C locale and drops trailing zeros, matching a hand-written file.
    static func number(_ value: CGFloat) -> String { String(format: "%g", Double(value)) }

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

    static func cursorStyleToken(_ s: TerminalBehavior.CursorStyle) -> String {
        switch s {
        case .block: return "block"
        case .bar: return "bar"
        case .underline: return "underline"
        }
    }

    static func parseCursorStyle(_ text: String) -> TerminalBehavior.CursorStyle? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "block": return .block
        case "bar": return .bar
        case "underline": return .underline
        default: return nil
        }
    }

    static func boolToken(_ on: Bool) -> String { on ? "true" : "false" }

    static func hideToolbarButtonsToken(_ hidden: Set<ToolbarButton>) -> String {
        ToolbarButton.allCases.filter(hidden.contains).map(\.rawValue).joined(separator: ",")
    }
}
