import CoreGraphics

public enum Direction: Sendable, Hashable {
    case left, right, up, down

    /// The reverse direction — used to record the return hop for directional focus memory.
    public var opposite: Direction {
        switch self {
        case .left: return .right
        case .right: return .left
        case .up: return .down
        case .down: return .up
        }
    }
}

/// Geometric nearest-neighbor pane navigation (ported from the prototype). Returns
/// the id of the closest pane in `direction`, or nil if none lies that way.
public func nearestLeaf(from: PaneID, frames: [PaneID: CGRect], direction: Direction) -> PaneID? {
    guard let src = frames[from] else { return nil }
    let fcx = src.midX
    let fcy = src.midY

    var best: (id: PaneID, score: CGFloat)?
    for (id, r) in frames where id != from {
        let dx = r.midX - fcx
        let dy = r.midY - fcy

        let primary: CGFloat
        let perp: CGFloat
        switch direction {
        case .left: if dx >= -4 { continue }; primary = -dx; perp = abs(dy)
        case .right: if dx <= 4 { continue }; primary = dx; perp = abs(dy)
        case .up: if dy >= -4 { continue }; primary = -dy; perp = abs(dx)
        case .down: if dy <= 4 { continue }; primary = dy; perp = abs(dx)
        }
        let score = primary + perp * 2
        if let current = best {
            if score < current.score || (score == current.score && id.raw < current.id.raw) {
                best = (id, score)
            }
        } else {
            best = (id, score)
        }
    }
    return best?.id
}
