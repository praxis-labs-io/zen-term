import Foundation

public extension PaneTree {
    func splitting(_ leaf: PaneID, axis: SplitAxis, newLeaf: PaneID, newSplit: SplitID) -> PaneTree {
        guard let newRoot = PaneNode.split(node: root, at: leaf, axis: axis, newLeaf: newLeaf, newSplit: newSplit) else {
            return self
        }
        return PaneTree(root: newRoot, focusedLeaf: newLeaf)
    }

    func closing(_ leaf: PaneID) -> PaneTree? {
        guard root.contains(leaf) else { return self }
        guard let result = PaneNode.close(node: root, leaf: leaf) else {
            return nil // closed the only leaf
        }
        let newFocus: PaneID
        if leaf == focusedLeaf {
            newFocus = result.promotedFocus ?? result.node.firstLeaf
        } else {
            newFocus = result.node.contains(focusedLeaf) ? focusedLeaf : result.node.firstLeaf
        }
        return PaneTree(root: result.node, focusedLeaf: newFocus)
    }

    func settingRatio(_ split: SplitID, to ratio: Double) -> PaneTree {
        PaneTree(root: PaneNode.setRatio(node: root, split: split, ratio: ratio), focusedLeaf: focusedLeaf)
    }
}

extension PaneNode {
    /// Returns a new node with `leaf` replaced by a split of [leaf, newLeaf], or nil if `leaf` absent.
    static func split(node: PaneNode, at leaf: PaneID, axis: SplitAxis, newLeaf: PaneID, newSplit: SplitID) -> PaneNode? {
        switch node {
        case let .leaf(id):
            guard id == leaf else { return nil }
            return .split(id: newSplit, axis: axis, ratio: 0.5, a: .leaf(id), b: .leaf(newLeaf))
        case let .split(id, ax, ratio, a, b):
            if let na = split(node: a, at: leaf, axis: axis, newLeaf: newLeaf, newSplit: newSplit) {
                return .split(id: id, axis: ax, ratio: ratio, a: na, b: b)
            }
            if let nb = split(node: b, at: leaf, axis: axis, newLeaf: newLeaf, newSplit: newSplit) {
                return .split(id: id, axis: ax, ratio: ratio, a: a, b: nb)
            }
            return nil
        }
    }

    /// Result of a close: the new node (nil = whole subtree gone) and, when a split
    /// collapsed, the promoted sibling's firstLeaf (for focus).
    struct CloseResult { var node: PaneNode; var promotedFocus: PaneID? }

    static func close(node: PaneNode, leaf: PaneID) -> CloseResult? {
        switch node {
        case let .leaf(id):
            return id == leaf ? nil : CloseResult(node: node, promotedFocus: nil)
        case let .split(id, axis, ratio, a, b):
            if a.contains(leaf) {
                guard let r = close(node: a, leaf: leaf) else {
                    // a collapsed entirely → promote b
                    return CloseResult(node: b, promotedFocus: b.firstLeaf)
                }
                return CloseResult(node: .split(id: id, axis: axis, ratio: ratio, a: r.node, b: b),
                                   promotedFocus: r.promotedFocus)
            }
            if b.contains(leaf) {
                guard let r = close(node: b, leaf: leaf) else {
                    return CloseResult(node: a, promotedFocus: a.firstLeaf)
                }
                return CloseResult(node: .split(id: id, axis: axis, ratio: ratio, a: a, b: r.node),
                                   promotedFocus: r.promotedFocus)
            }
            return CloseResult(node: node, promotedFocus: nil)
        }
    }

    static func setRatio(node: PaneNode, split: SplitID, ratio: Double) -> PaneNode {
        switch node {
        case .leaf: return node
        case let .split(id, axis, r, a, b):
            if id == split { return .split(id: id, axis: axis, ratio: ratio, a: a, b: b) }
            return .split(id: id, axis: axis, ratio: r,
                          a: setRatio(node: a, split: split, ratio: ratio),
                          b: setRatio(node: b, split: split, ratio: ratio))
        }
    }
}
