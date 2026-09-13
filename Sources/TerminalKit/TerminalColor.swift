import AppKit

public struct TerminalColor: Sendable, Equatable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses `#rrggbb` or `#rgb`, `#` optional, case-insensitive. Nil for any other form, named colors included.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        let sixDigit: String
        switch text.count {
        case 3: sixDigit = text.map { "\($0)\($0)" }.joined()
        case 6: sixDigit = text
        default: return nil
        }
        guard let value = UInt32(sixDigit, radix: 16) else { return nil }
        self.init(
            red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8(value & 0xFF))
    }

    /// `#rrggbb`, the inverse of `init?(hex:)`.
    public var hex: String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }

    /// W3C perceived luminance at or below 0.5, the same test ghostty uses to tell light from dark.
    public var isDark: Bool {
        let luminance =
            0.299 * (Double(red) / 255) + 0.587 * (Double(green) / 255)
            + 0.114 * (Double(blue) / 255)
        return luminance <= 0.5
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255.0, green: CGFloat(green) / 255.0, blue: CGFloat(blue) / 255.0, alpha: 1)
    }
}
