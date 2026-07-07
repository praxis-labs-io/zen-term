/// Which leaves were created, removed, or retained between two tree snapshots.
public struct PaneDiff: Equatable, Sendable {
    public let created: [PaneID]
    public let removed: [PaneID]
    public let retained: [PaneID]
}

public func paneDiff(from old: [PaneID], to new: [PaneID]) -> PaneDiff {
    let oldSet = Set(old)
    let newSet = Set(new)
    return PaneDiff(
        created: new.filter { !oldSet.contains($0) },
        removed: old.filter { !newSet.contains($0) },
        retained: new.filter { oldSet.contains($0) }
    )
}
