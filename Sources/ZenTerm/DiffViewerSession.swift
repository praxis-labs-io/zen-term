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
/// and their place in the tree. Held by the `TabController` for the repo that tab last opened and
/// handed to each `DiffViewerOverlay`, so ⌘D lands you back where you left off instead of at the top
/// of the tree.
///
/// Per tab rather than per window (ZEN-298): a window-level slot meant two tabs on two repos shared one
/// session, so opening the viewer in the second discarded the first's place, base, and highlight cache.
///
/// In memory only, and only for one repo at a time *per tab*: opening the viewer on a different repo in
/// the same tab starts fresh rather than accumulating state for every repo that tab has ever visited.
final class DiffViewerSession {
    let repoRoot: URL
    let highlights = DiffHighlightStore()
    /// The last successful **default-base** load. A picked base is a transient override, so its status
    /// is never stamped here — see `baseOverride`, which is what makes the reopen re-run it.
    var lastStatus: GitDiffRunner.StatusLoad?
    /// The base the reader picked in the dropdown, nil for the repo's default. Restored on reopen, which
    /// is why a session carrying one can't render `lastStatus`: that status is the *default* base's.
    var baseOverride: String?
    /// The branch the reader pointed the viewer at, nil for the checkout's own head (ZEN-313). Restored
    /// on reopen for the same reason as `baseOverride`, and it disqualifies `lastStatus` the same way:
    /// that status is the checkout's, not the picked branch's.
    var headOverride: GitDiffRunner.BranchOption?
    var place = DiffViewerPlace()

    init(repoRoot: URL) {
        self.repoRoot = repoRoot
    }
}
