import Foundation

public struct PaneID: Hashable, Sendable {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
}

public struct SplitID: Hashable, Sendable {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
}

/// `.vertical` places panes side by side; `.horizontal` stacks them.
public enum SplitAxis: Sendable { case vertical, horizontal }

public indirect enum PaneNode: Sendable {
    case leaf(PaneID)
    case split(id: SplitID, axis: SplitAxis, ratio: Double, a: PaneNode, b: PaneNode)
}

public extension PaneNode {
    /// Leaf ids in a-before-b order.
    var leafIDs: [PaneID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, _, let a, let b): return a.leafIDs + b.leafIDs
        }
    }

    /// The leaf reached by always descending into `a`.
    var firstLeaf: PaneID {
        switch self {
        case .leaf(let id): return id
        case .split(_, _, _, let a, _): return a.firstLeaf
        }
    }

    func contains(_ id: PaneID) -> Bool {
        switch self {
        case .leaf(let leafID):
            return leafID == id
        case .split(_, _, _, let a, let b):
            return a.contains(id) || b.contains(id)
        }
    }
}
