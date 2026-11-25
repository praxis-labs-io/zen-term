import AppKit

// The light from above and shade at the foot that every chip shares: a process chip and an SSH host's emblem.
enum ChipSheen {
    // An alpha mask, not a color, the same on every theme.
    static let colors = [
        NSColor(white: 1, alpha: 0.2), NSColor(white: 1, alpha: 0), NSColor(white: 0, alpha: 0.2),
    ].map(\.cgColor)
    private static let stops: [NSNumber] = [0, 0.45, 1]

    static func shape(_ layer: CAGradientLayer) {
        layer.colors = colors
        layer.locations = stops
        layer.startPoint = CGPoint(x: 0.5, y: 1)
        layer.endPoint = CGPoint(x: 0.5, y: 0)
    }
}
