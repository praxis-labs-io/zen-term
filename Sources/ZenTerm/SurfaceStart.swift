import TerminalKit

// How a tab starts a surface it made: at once, or held back until a host's shared connection is up.
typealias SurfaceStart = (TerminalSurface, SurfaceID, TerminalSurfaceConfig) -> Void
