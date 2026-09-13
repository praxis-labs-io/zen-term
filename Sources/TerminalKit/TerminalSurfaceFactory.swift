public enum TerminalSurfaceFactory {
    #if DEBUG
        /// When set, `make()` returns this instead of a libghostty surface. Debug builds only.
        public static var makeOverride: (() -> TerminalSurface)?
    #endif

    public static func make() -> TerminalSurface {
        #if DEBUG
            if let makeOverride { return makeOverride() }
        #endif
        return GhosttySurface()
    }
}
