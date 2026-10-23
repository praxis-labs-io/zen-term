/// Names one terminal surface for the window's lifetime, across panes, drawers and floats.
struct SurfaceID: Hashable {
    let raw: Int
}

// `PaneID` restarts at 1 in every tab's canvas and drawers have no key at all, so attention needs its own.
enum SurfaceIDs {
    private static var next = 1

    /// Never reused, so a late event from a dead surface cannot land on a live one. Main-thread only.
    static func mint() -> SurfaceID {
        defer { next += 1 }
        return SurfaceID(raw: next)
    }
}
