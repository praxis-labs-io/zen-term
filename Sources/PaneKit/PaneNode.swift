import Foundation

/// Identifies a terminal-hosting leaf pane. Values are supplied by the caller
/// (deterministic — no global mutable state in PaneKit).
public struct PaneID: Hashable, Sendable {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
}

/// A split's identity (distinct from a leaf's).
public struct SplitID: Hashable, Sendable {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
}

/// Split orientation. `.vertical` = a | b side by side; `.horizontal` = a / b stacked.
public enum SplitAxis: Sendable { case vertical, horizontal }

/// The recursive pane layout for one window. A value type — all edits produce a new tree.
public indirect enum PaneNode: Sendable {
    case leaf(PaneID)
    case split(id: SplitID, axis: SplitAxis, ratio: Double, a: PaneNode, b: PaneNode)
}

public extension PaneNode {
    /// Leaf ids in left-to-right / a-before-b order.
    var leafIDs: [PaneID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, _, let a, let b): return a.leafIDs + b.leafIDs
        }
    }

    /// The first leaf reached by always descending into `a`.
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
