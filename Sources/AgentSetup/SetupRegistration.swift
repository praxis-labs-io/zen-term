/// The step that tells an agent to load what setup placed, read once before an install or remove writes anything.
public protocol SetupRegistration {
    /// Any entry setup recognizes as its own, even one it would rewrite.
    var hasEntry: Bool { get }
    /// The entry is exactly the one setup writes.
    var isCurrent: Bool { get }

    /// Writes the entry; returns its change line, nil when it was already current.
    mutating func register() throws(SetupError) -> String?
    /// Deletes setup's entry and keeps every other; returns its change line, nil when there was none.
    mutating func unregister() throws(SetupError) -> String?
}
