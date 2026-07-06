import Foundation

/// Identifies a terminal-hosting leaf pane. Values are supplied by the caller
/// (deterministic — no global mutable state in PaneKit).
public struct PaneID: Hashable, Sendable {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
}
