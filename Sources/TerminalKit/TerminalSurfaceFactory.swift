/// The one swap point. Chrome only ever calls `TerminalSurfaceFactory.make()`.
public enum TerminalBackend {
    case swiftTerm
    /// libghostty (ZEN-40 spike) — GPU/Metal backend behind the same seam.
    case ghostty
}

public enum TerminalSurfaceFactory {
    public static var backend: TerminalBackend = .swiftTerm

    public static func make() -> TerminalSurface {
        switch backend {
        case .swiftTerm:
            return SwiftTermSurface()
        case .ghostty:
            return GhosttySurface()
        }
    }
}
