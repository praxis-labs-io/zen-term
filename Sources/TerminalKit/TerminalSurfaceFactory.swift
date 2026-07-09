/// The one swap point. Chrome only ever calls `TerminalSurfaceFactory.make()`.
public enum TerminalBackend {
    /// SwiftTerm — the original CPU backend, kept as the escape hatch.
    case swiftTerm
    /// libghostty — GPU/Metal backend behind the same seam. The default (ZEN-45).
    case ghostty
}

public enum TerminalSurfaceFactory {
    public static var backend: TerminalBackend = .ghostty

    public static func make() -> TerminalSurface {
        switch backend {
        case .swiftTerm:
            return SwiftTermSurface()
        case .ghostty:
            return GhosttySurface()
        }
    }
}
