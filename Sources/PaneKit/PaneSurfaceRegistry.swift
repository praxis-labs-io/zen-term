import TerminalKit

/// Owns the live surface per leaf. Retained leaves keep their surface across any tree change.
public final class PaneSurfaceRegistry {
    private var surfaces: [PaneID: TerminalSurface] = [:]
    private let makeSurface: () -> TerminalSurface

    public init(makeSurface: @escaping () -> TerminalSurface) {
        self.makeSurface = makeSurface
    }

    public func surface(for id: PaneID) -> TerminalSurface? { surfaces[id] }
    public var ids: Set<PaneID> { Set(surfaces.keys) }
    public var allSurfaces: [TerminalSurface] { Array(surfaces.values) }

    public func terminateAll() {
        for surface in surfaces.values { surface.terminate() }
        surfaces.removeAll()
    }

    /// Terminates removed leaves' surfaces and returns new ones for the caller to configure and start.
    @discardableResult
    public func apply(_ diff: PaneDiff) -> [(id: PaneID, surface: TerminalSurface)] {
        for id in diff.removed {
            surfaces[id]?.terminate()
            surfaces[id] = nil
        }
        var created: [(id: PaneID, surface: TerminalSurface)] = []
        for id in diff.created {
            let surface = makeSurface()
            surfaces[id] = surface
            created.append((id, surface))
        }
        return created
    }
}
