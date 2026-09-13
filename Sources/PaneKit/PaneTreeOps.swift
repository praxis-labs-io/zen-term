import Foundation

public extension PaneTree {
    func splitting(_ leaf: PaneID, axis: SplitAxis, newLeaf: PaneID, newSplit: SplitID) -> PaneTree {
        guard let newRoot = PaneNode.splitting(node: root, at: leaf, axis: axis, newLeaf: newLeaf, newSplit: newSplit)
        else {
            return self
        }
        return PaneTree(root: newRoot, focusedLeaf: newLeaf)
    }

    /// Returns nil when `leaf` is the only leaf. Focus moves to the promoted sibling when it closes the focused leaf.
    func closing(_ leaf: PaneID) -> PaneTree? {
        guard root.contains(leaf) else { return self }
        guard let result = PaneNode.close(node: root, leaf: leaf) else {
            return nil
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

    /// The divider a resize of `leaf` moves: the grow side first (`positive` is right or down), else the
    /// opposite side. Nil when `leaf` has no ancestor split on `axis`.
    func edgeSplitID(for leaf: PaneID, axis: SplitAxis, positive: Bool) -> SplitID? {
        guard root.contains(leaf) else { return nil }
        return root.nearestSplit(to: leaf, axis: axis, onSideA: positive)
            ?? root.nearestSplit(to: leaf, axis: axis, onSideA: !positive)
    }

    func ratio(of split: SplitID) -> Double? { root.ratio(of: split) }
}

extension PaneNode {
    static func splitting(node: PaneNode, at leaf: PaneID, axis: SplitAxis, newLeaf: PaneID, newSplit: SplitID)
        -> PaneNode?
    {
        switch node {
        case .leaf(let id):
            guard id == leaf else { return nil }
            return .split(id: newSplit, axis: axis, ratio: 0.5, a: .leaf(id), b: .leaf(newLeaf))
        case .split(let id, let ax, let ratio, let a, let b):
            if let na = splitting(node: a, at: leaf, axis: axis, newLeaf: newLeaf, newSplit: newSplit) {
                return .split(id: id, axis: ax, ratio: ratio, a: na, b: b)
            }
            if let nb = splitting(node: b, at: leaf, axis: axis, newLeaf: newLeaf, newSplit: newSplit) {
                return .split(id: id, axis: ax, ratio: ratio, a: a, b: nb)
            }
            return nil
        }
    }

    struct CloseResult { var node: PaneNode; var promotedFocus: PaneID? }

    static func close(node: PaneNode, leaf: PaneID) -> CloseResult? {
        switch node {
        case .leaf(let id):
            return id == leaf ? nil : CloseResult(node: node, promotedFocus: nil)
        case .split(let id, let axis, let ratio, let a, let b):
            if a.contains(leaf) {
                guard let r = close(node: a, leaf: leaf) else {
                    return CloseResult(node: b, promotedFocus: b.firstLeaf)
                }
                return CloseResult(
                    node: .split(id: id, axis: axis, ratio: ratio, a: r.node, b: b),
                    promotedFocus: r.promotedFocus)
            }
            if b.contains(leaf) {
                guard let r = close(node: b, leaf: leaf) else {
                    return CloseResult(node: a, promotedFocus: a.firstLeaf)
                }
                return CloseResult(
                    node: .split(id: id, axis: axis, ratio: ratio, a: a, b: r.node),
                    promotedFocus: r.promotedFocus)
            }
            return CloseResult(node: node, promotedFocus: nil)
        }
    }

    func nearestSplit(to leaf: PaneID, axis: SplitAxis, onSideA: Bool) -> SplitID? {
        guard case .split(let id, let ax, _, let a, let b) = self else { return nil }
        let inA = a.contains(leaf)
        let child = inA ? a : b
        if let deeper = child.nearestSplit(to: leaf, axis: axis, onSideA: onSideA) { return deeper }
        return (ax == axis && inA == onSideA) ? id : nil
    }

    func ratio(of id: SplitID) -> Double? {
        switch self {
        case .leaf: return nil
        case .split(let sid, _, let r, let a, let b):
            if sid == id { return r }
            return a.ratio(of: id) ?? b.ratio(of: id)
        }
    }

    static func setRatio(node: PaneNode, split: SplitID, ratio: Double) -> PaneNode {
        switch node {
        case .leaf: return node
        case .split(let id, let axis, let r, let a, let b):
            if id == split { return .split(id: id, axis: axis, ratio: ratio, a: a, b: b) }
            return .split(
                id: id, axis: axis, ratio: r,
                a: setRatio(node: a, split: split, ratio: ratio),
                b: setRatio(node: b, split: split, ratio: ratio))
        }
    }
}
