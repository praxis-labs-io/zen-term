import Foundation

/// The full pane state for one window: the layout tree plus which leaf is focused.
public struct PaneTree: Sendable {
    public var root: PaneNode
    public var focusedLeaf: PaneID

    public init(root: PaneNode, focusedLeaf: PaneID) {
        self.root = root
        self.focusedLeaf = focusedLeaf
    }

    /// A fresh single-leaf tree focused on that leaf.
    public init(singleLeaf id: PaneID) {
        self.root = .leaf(id)
        self.focusedLeaf = id
    }

    public var leafIDs: [PaneID] { root.leafIDs }
    public func contains(_ id: PaneID) -> Bool { root.contains(id) }
}
