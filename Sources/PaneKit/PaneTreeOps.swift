import Foundation

public extension PaneTree {
    func splitting(_ leaf: PaneID, axis: SplitAxis, newLeaf: PaneID, newSplit: SplitID) -> PaneTree {
        guard let newRoot = PaneNode.splitting(node: root, at: leaf, axis: axis, newLeaf: newLeaf, newSplit: newSplit) else {
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

    /// The split whose divider a resize should move for the focused `leaf` along `axis` in
    /// a key's screen direction (`positive` = rightward l / downward j). Prefers the
    /// grow-side divider — the neighbor the pane would expand into — and falls back to the
    /// opposite divider so an edge pane still resizes (shrinking). Nil when the leaf has no
    /// split of `axis` in its ancestry. The caller reads the split's rendered extent to
    /// clamp the ratio to a pixel minimum, which the pure tree can't know.
    func edgeSplitID(for leaf: PaneID, axis: SplitAxis, positive: Bool) -> SplitID? {
        guard root.contains(leaf) else { return nil }   // `nearestSplit` assumes the leaf is present
        return root.nearestSplit(to: leaf, axis: axis, onSideA: positive)
            ?? root.nearestSplit(to: leaf, axis: axis, onSideA: !positive)
    }

    /// The ratio of `split`, or nil if it isn't in the tree.
    func ratio(of split: SplitID) -> Double? { root.ratio(of: split) }
}

extension PaneNode {
    /// Returns a new node with `leaf` replaced by a split of [leaf, newLeaf], or nil if `leaf` absent.
    static func splitting(node: PaneNode, at leaf: PaneID, axis: SplitAxis, newLeaf: PaneID, newSplit: SplitID) -> PaneNode? {
        switch node {
        case let .leaf(id):
            guard id == leaf else { return nil }
            return .split(id: newSplit, axis: axis, ratio: 0.5, a: .leaf(id), b: .leaf(newLeaf))
        case let .split(id, ax, ratio, a, b):
            if let na = splitting(node: a, at: leaf, axis: axis, newLeaf: newLeaf, newSplit: newSplit) {
                return .split(id: id, axis: ax, ratio: ratio, a: na, b: b)
            }
            if let nb = splitting(node: b, at: leaf, axis: axis, newLeaf: newLeaf, newSplit: newSplit) {
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

    /// The deepest ancestor split of `leaf` whose axis is `axis` and whose subtree holding
    /// `leaf` is the a-side (`onSideA`) or b-side. Deepest is the divider closest to the
    /// leaf — the one that resizes it most locally. Nil when no split on the leaf's path
    /// matches both axis and side.
    func nearestSplit(to leaf: PaneID, axis: SplitAxis, onSideA: Bool) -> SplitID? {
        guard case let .split(id, ax, _, a, b) = self else { return nil }
        let inA = a.contains(leaf)
        let child = inA ? a : b
        if let deeper = child.nearestSplit(to: leaf, axis: axis, onSideA: onSideA) { return deeper }
        return (ax == axis && inA == onSideA) ? id : nil
    }

    /// The ratio of the split identified by `id`, or nil if it isn't in this subtree.
    func ratio(of id: SplitID) -> Double? {
        switch self {
        case .leaf: return nil
        case let .split(sid, _, r, a, b):
            if sid == id { return r }
            return a.ratio(of: id) ?? b.ratio(of: id)
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
