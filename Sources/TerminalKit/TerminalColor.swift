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

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255.0, green: CGFloat(green) / 255.0, blue: CGFloat(blue) / 255.0, alpha: 1)
    }
}
