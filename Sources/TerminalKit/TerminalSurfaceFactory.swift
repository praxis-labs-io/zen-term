/// The one swap point. Chrome only ever calls `TerminalSurfaceFactory.make()`.
public enum TerminalBackend {
    case swiftTerm
    // case ghostty  — added when backend B (libghostty) lands in a later epic.
}

public enum TerminalSurfaceFactory {
    public static var backend: TerminalBackend = .swiftTerm

    public static func make() -> TerminalSurface {
        switch backend {
        case .swiftTerm:
            return SwiftTermSurface()
        }
    }
}
