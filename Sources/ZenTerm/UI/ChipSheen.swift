import AppKit

// The light from above and shade at the foot that every chip shares: a process chip and an SSH host's emblem.
enum ChipSheen {
    // An emblem's tile is several chips tall, where the chip's short ramps read as a band, so its ramps run longer and lighter.
    enum Spread { case chip, tile }

    // An alpha mask, not a color, the same on every theme. The tile's halves fade to their own clear, since its longer ramp from white to black would lighten through grey.
    static func colors(_ spread: Spread) -> [CGColor] {
        let alphas: [(white: CGFloat, alpha: CGFloat)] =
            switch spread {
            case .chip: [(1, 0.2), (1, 0), (0, 0.2)]
            case .tile: [(1, 0.14), (1, 0.05), (1, 0), (0, 0), (0, 0.05), (0, 0.14)]
            }
        return alphas.map { NSColor(white: $0.white, alpha: $0.alpha).cgColor }
    }

    private static func stops(_ spread: Spread) -> [NSNumber] {
        switch spread {
        case .chip: [0, 0.45, 1]
        case .tile: [0, 0.3, 0.6, 0.6, 0.82, 1]
        }
    }

    static func shape(_ layer: CAGradientLayer, _ spread: Spread) {
        layer.colors = colors(spread)
        layer.locations = stops(spread)
        layer.startPoint = CGPoint(x: 0.5, y: 1)
        layer.endPoint = CGPoint(x: 0.5, y: 0)
    }
}
