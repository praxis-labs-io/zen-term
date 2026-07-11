import CoreGraphics
import Foundation

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

    static func reduceMotionIndex(_ r: GeneralConfig.ReduceMotion) -> Int {
        switch r {
        case .system: return 0
        case .on: return 1
        case .off: return 2
        }
    }

    static func reduceMotion(fromIndex index: Int) -> GeneralConfig.ReduceMotion {
        switch index {
        case 1: return .on
        case 2: return .off
        default: return .system
        }
    }

    static func joinArgs(_ args: [String]) -> String { args.joined(separator: " ") }

    static func splitArgs(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
