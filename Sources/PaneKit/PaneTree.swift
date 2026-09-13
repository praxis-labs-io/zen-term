import Foundation

/// A window's layout tree plus its focused leaf.
public struct PaneTree: Sendable {
    public var root: PaneNode
    public var focusedLeaf: PaneID

    public init(root: PaneNode, focusedLeaf: PaneID) {
        self.root = root
        self.focusedLeaf = focusedLeaf
    }

    public init(singleLeaf id: PaneID) {
        self.root = .leaf(id)
        self.focusedLeaf = id
    }

    public var leafIDs: [PaneID] { root.leafIDs }
    public func contains(_ id: PaneID) -> Bool { root.contains(id) }
}
