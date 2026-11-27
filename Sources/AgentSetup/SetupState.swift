/// What an `AgentInstaller` finds installed in its agent's config folder.
public enum SetupState: Equatable, Sendable {
    case notInstalled
    /// Every part is installed, and each file differs from this build's only as an earlier build shipped it.
    case outdated
    /// A file holds edits no build shipped, a part is missing, or the registration is not the one setup writes,
    /// so updating would undo the user's change.
    case edited
    /// A later build installed these files and they are untouched, so this build must not replace them.
    case newer
    case current
}
