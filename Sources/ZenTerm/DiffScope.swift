import Foundation

/// The three slices of a repo's state the diff viewer shows as stacked sections, top to bottom.
/// `.unstaged` is the working tree against the index (plus untracked files); `.staged` is the index
/// against HEAD; `.committed` is HEAD against the branch's fork point (the commits on this branch).
enum DiffScope: String, CaseIterable {
    case unstaged
    case staged
    case committed
}
