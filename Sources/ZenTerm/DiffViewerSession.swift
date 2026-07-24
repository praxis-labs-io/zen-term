import Foundation

/// Where the reader was in the diff viewer: which folders they folded shut, which file they had open,
/// and where the cursor sat inside it. Captured before a load rebuilds the tree and re-applied after,
/// so a background refresh or a base switch doesn't snap the card back to fully-expanded and the first
/// file while someone is mid-review (ZEN-233).
struct DiffViewerPlace {
    /// `DiffOutlineItem.identity` for each row folded shut. Folds are recorded rather than expansions
    /// because fully-expanded is the default: a directory that first appears in a reload should come up
    /// open, and only the rows a person deliberately closed should come back closed.
    var collapsed: Set<String> = []
    /// The selected row's identity, and the file path under it. Both, because a file `git add`ed while
    /// the viewer is up moves from Unstaged to Staged — a new identity, but the same file to the person
    /// reading it, so the path is the looser second try.
    var selectedIdentity: String?
    var selectedPath: String?
    /// The cursor's line numbers, never its row index: the content shifts under a reload, and the two
    /// layouts index differently anyway (`DiffSelection.row(for:in:)` re-finds it).
    var cursorLine: DiffSelection.LineNumbers?
}

/// What the diff viewer remembers about one repo between opens: the last status (so a reopen renders
/// instantly and refreshes behind the card), the syntax-highlight cache, the base the reader picked,
/// and their place in the tree. Held by `WindowController` for the repo it last opened and handed to
/// each `DiffViewerOverlay`, so ⌘D lands you back where you left off instead of at the top of the tree.
///
/// In memory only, and only for one repo at a time: opening the viewer on a different repo starts fresh
/// rather than accumulating state for every repo the window has ever visited.
final class DiffViewerSession {
    let repoRoot: URL
    let highlights = DiffHighlightStore()
    /// The last successful **default-base** load. A picked base is a transient override, so its status
    /// is never stamped here — see `baseOverride`, which is what makes the reopen re-run it.
    var lastStatus: GitDiffRunner.StatusLoad?
    /// The base the reader picked in the dropdown, nil for the repo's default. Restored on reopen, which
    /// is why a session carrying one can't render `lastStatus`: that status is the *default* base's.
    var baseOverride: String?
    var place = DiffViewerPlace()

    init(repoRoot: URL) {
        self.repoRoot = repoRoot
    }
}
