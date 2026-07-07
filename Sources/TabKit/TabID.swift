/// Identifies a tab within one window. Values are supplied by the caller
/// (deterministic — no global mutable state in TabKit), like PaneID.
public struct TabID: Hashable, Sendable {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
}
