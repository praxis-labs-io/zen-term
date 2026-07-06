import TerminalKit

/// Owns the live `TerminalSurface` per leaf. Applying a diff creates surfaces for
/// new leaves (via the injected factory), terminates surfaces for removed leaves,
/// and leaves retained surfaces untouched — so a retained leaf keeps its running
/// shell, scrollback, and first-responder state across any tree restructure.
public final class PaneSurfaceRegistry {
    private var surfaces: [PaneID: TerminalSurface] = [:]
    private let makeSurface: () -> TerminalSurface

    public init(makeSurface: @escaping () -> TerminalSurface) {
        self.makeSurface = makeSurface
    }

    public func surface(for id: PaneID) -> TerminalSurface? { surfaces[id] }
    public var ids: Set<PaneID> { Set(surfaces.keys) }

    /// Applies the diff and returns the newly-created (id, surface) pairs so the
    /// caller can set their delegate and `start(...)` them with the right config.
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
