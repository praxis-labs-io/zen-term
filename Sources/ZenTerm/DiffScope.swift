import Foundation

/// Which slice of the repo's history the diff viewer shows. `.branch` is the union of the
/// other two: everything on this branch since it forked from the base, working-tree edits
/// folded in. `.committed` is the same fork point up to HEAD (the PR-equivalent). `.uncommitted`
/// is HEAD up to the working tree (only what hasn't been committed yet).
enum DiffScope: String, CaseIterable {
    case branch
    case committed
    case uncommitted
}
