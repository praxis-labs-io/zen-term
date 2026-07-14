/// The one place the chrome asks for a terminal. Chrome only ever calls
/// `TerminalSurfaceFactory.make()`; libghostty is the sole backend (ZEN-45, ZEN-66).
public enum TerminalSurfaceFactory {
    #if DEBUG
        /// Test seam: when set, `make()` returns this instead of a live libghostty surface, so
        /// tests can mount the chrome with a headless stub rather than booting a real ghostty
        /// app. Compiled out of release builds entirely, mirroring `Theme.setCurrentForTesting`.
        public static var makeOverride: (() -> TerminalSurface)?
    #endif

    public static func make() -> TerminalSurface {
        #if DEBUG
            if let makeOverride { return makeOverride() }
        #endif
        return GhosttySurface()
    }
}
