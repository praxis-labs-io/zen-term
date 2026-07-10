import AppKit

/// An 8-bit-per-channel RGB color — the seam's backend-neutral color vocabulary.
/// Backends translate this into their own representation.
public struct TerminalColor: Sendable, Equatable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parse a `#rrggbb` or `#rgb` hex string (case-insensitive, surrounding
    /// whitespace tolerated). The inverse of `hex`; `nil` for any other form.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#") else { return nil }
        text.removeFirst()
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

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255.0, green: CGFloat(green) / 255.0, blue: CGFloat(blue) / 255.0, alpha: 1)
    }
}
