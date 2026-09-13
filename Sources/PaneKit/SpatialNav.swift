import CoreGraphics

public enum Direction: Sendable, Hashable {
    case left, right, up, down

    public var opposite: Direction {
        switch self {
        case .left: return .right
        case .right: return .left
        case .up: return .down
        case .down: return .up
        }
    }
}

/// The closest pane straight in `direction` from `from`, or nil. A diagonal pane never qualifies.
public func nearestLeaf(from: PaneID, frames: [PaneID: CGRect], direction: Direction) -> PaneID? {
    guard let src = frames[from] else { return nil }
    let fcx = src.midX
    let fcy = src.midY

    var best: (id: PaneID, score: CGFloat)?
    for (id, r) in frames where id != from {
        guard liesDirectionally(src: src, candidate: r, direction: direction) else { continue }
        let dx = r.midX - fcx
        let dy = r.midY - fcy

        let primary: CGFloat
        let perp: CGFloat
        switch direction {
        case .left: primary = -dx; perp = abs(dy)
        case .right: primary = dx; perp = abs(dy)
        case .up: primary = -dy; perp = abs(dx)
        case .down: primary = dy; perp = abs(dx)
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

/// Whether `candidate` passes the same straight-neighbor filter `nearestLeaf` uses.
public func lies(
    _ candidate: PaneID, inDirection direction: Direction,
    from origin: PaneID, frames: [PaneID: CGRect]
) -> Bool {
    guard let src = frames[origin], let r = frames[candidate] else { return false }
    return liesDirectionally(src: src, candidate: r, direction: direction)
}

// Requires perpendicular overlap so a full-height drawer is never a vertical hop from a bottom drawer.
private func liesDirectionally(src: CGRect, candidate r: CGRect, direction: Direction) -> Bool {
    let dx = r.midX - src.midX
    let dy = r.midY - src.midY
    switch direction {
    case .left, .right:
        let overlapsY = min(src.maxY, r.maxY) > max(src.minY, r.minY)
        return overlapsY && (direction == .left ? dx < -4 : dx > 4)
    case .up, .down:
        let overlapsX = min(src.maxX, r.maxX) > max(src.minX, r.minX)
        return overlapsX && (direction == .up ? dy < -4 : dy > 4)
    }
}
