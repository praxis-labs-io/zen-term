import AppKit
import TerminalKit

/// The `⌘P` workspace picker: a modal palette over the tab's tile region listing the
/// workspaces configured in `~/.config/zen-term/workspaces`, led by a persistent
/// "＋ New Workspace…" row that opens the Add-Workspace form. Enter opens the selected workspace in
/// a new tab, Shift+Enter replaces the current tab, Esc / backdrop click dismiss. Built on
/// `PaletteOverlay`, which owns the card/list/keyboard scaffolding; this supplies the rows + filter.
final class RepoPickerOverlay: PaletteOverlay {
    /// A leading action row, then one row per configured workspace, each followed by the worktrees
    /// of its repo.
    private enum Row {
        case add
        case workspace(Workspace)
        case worktree(Worktree, parent: Workspace)
    }

    /// (selected workspace, replaceCurrentTab). `replaceCurrentTab` is Shift+Enter.
    private let onChoose: (Workspace, Bool) -> Void
    /// Open the Add-Workspace form (the ＋ row, and the empty state when there are no workspaces).
    private let onAddWorkspace: () -> Void

    private let entries: [Workspace]
    /// Keyed by the workspace's standardized path, filled in when the background listing lands.
    private var listings: [URL: WorktreeListing] = [:]

    /// This picker's probes in flight, cancelled when it goes away so a closed picker stops
    /// costing the queue. Held per picker rather than cancelled queue-wide: another window's
    /// picker is probing the same queue and its answers are not this one's to drop.
    private var churnRefresh: GitRepoStatus.RefreshToken?
    private var worktreeRefresh: GitRepoStatus.RefreshToken?
    /// Common dir to the workspace that shows its worktrees, in config order. Recomputed when a
    /// listing lands, never when the query changes.
    private var worktreeOwners: [URL: URL] = [:]
    /// Every configured workspace's path, so a worktree that already has a workspace row of its
    /// own is not repeated as a child of one.
    private let configuredPaths: Set<URL>
    private var rows: [Row]
    /// Worktrees whose delete is running. A row for one of these is going away, so it renders as
    /// removing and refuses to open: a tab landed in it would start in a folder mid-delete.
    private let removals: WorktreeRemovalTracker

    init(
        entries: [Workspace], background: NSColor,
        removals: WorktreeRemovalTracker = WorktreeRemovalTracker(),
        onChoose: @escaping (Workspace, Bool) -> Void, onAddWorkspace: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.entries = entries
        self.removals = removals
        self.configuredPaths = Set(entries.map { $0.path.standardizedFileURL })
        self.rows = Self.rows(for: entries, listings: [:], configured: [], owners: [:])
        self.onChoose = onChoose
        self.onAddWorkspace = onAddWorkspace
        super.init(
            background: background,
            placeholder: "Search workspaces…",
            emptyText: "",  // never shown — the ＋ row is always present, so the list is never empty
            footerHints: Self.footerHints(),
            rowHeight: 32,
            onDismiss: onDismiss)

        // One background pass per open: the rows are up with whatever git status was already known,
        // and the branches fill in when the probes land. Per open rather than once per process, so
        // a branch switched in a shell shows up without a relaunch.
        GitRepoStatus.refresh(entries.map(\.path)) { [weak self] in self?.applyGitStatus() }
        // The counts run `git` rather than reading a file, so they land after the branch does
        // rather than holding it up.
        churnRefresh = GitRepoStatus.refreshChurn(entries.map(\.path)) { [weak self] in
            self?.applyGitStatus()
        }
        // Two `git` calls per workspace, so the worktree rows land last and insert themselves under
        // the workspace they belong to rather than holding the card back.
        relistWorktrees()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Ask git for every entry's worktrees again. Run once on open, and again when a removal
    /// finishes: `refreshRemovalState` re-renders from the listings already in hand, and those
    /// still name the folder that has just gone.
    ///
    /// The whole set rather than the one workspace that changed: this call supersedes the one
    /// before it, and a narrower call would strand this picker's other workspaces mid-probe.
    func relistWorktrees() {
        worktreeRefresh?.cancel()
        worktreeRefresh = GitRepoStatus.refreshWorktrees(entries.map(\.path)) {
            [weak self] path, listing in
            self?.setWorktrees(listing, for: path)
        }
    }

    deinit {
        churnRefresh?.cancel()
        worktreeRefresh?.cancel()
    }

    /// Re-read every workspace row's branch from `GitRepoStatus`.
    private func applyGitStatus() {
        for row in rowViews { (row as? RowView)?.applyGitStatus() }
    }

    /// Hand the picker one workspace's listing as the background pass answers for it, and
    /// re-render around it. The selection is put back by identity: rows arriving under the cursor
    /// must not move it, and a reload otherwise resets to the default.
    func setWorktrees(_ listing: WorktreeListing, for workspacePath: URL) {
        listings[workspacePath.standardizedFileURL] = listing
        worktreeOwners = Self.owners(among: entries, listings: listings)
        let held = rows.indices.contains(selected) ? rowIdentity(at: selected) : nil
        applyFilter(query: currentQuery)
        refreshRows(animated: true)
        reselect(byIdentity: held)
    }

    /// Which workspace shows the worktrees of each repo, decided once from config order.
    ///
    /// Two workspaces can be checkouts of one repo, and `worktree list` answers the same set for
    /// both. Deciding this from the filtered, re-sorted list would let a query move a worktree to
    /// a different parent and so open it with a different recipe. An empty listing never claims:
    /// a workspace inside a repo but not at its root resolves a common dir and lists nothing, and
    /// claiming there would hide the real checkout's worktrees.
    private static func owners(
        among workspaces: [Workspace], listings: [URL: WorktreeListing]
    ) -> [URL: URL] {
        var owners: [URL: URL] = [:]
        for workspace in workspaces {
            let path = workspace.path.standardizedFileURL
            guard let listing = listings[path], !listing.worktrees.isEmpty else { continue }
            let key = listing.commonDir ?? path
            if owners[key] == nil { owners[key] = path }
        }
        return owners
    }

    /// The ＋ row first, then a workspace row per entry, with a repo's worktrees under whichever
    /// workspace `owners` picked for it.
    private static func rows(
        for workspaces: [Workspace], listings: [URL: WorktreeListing], configured: Set<URL>,
        owners: [URL: URL]
    ) -> [Row] {
        var rows: [Row] = [.add]
        for workspace in workspaces {
            rows.append(.workspace(workspace))
            let path = workspace.path.standardizedFileURL
            guard let listing = listings[path], owners[listing.commonDir ?? path] == path else {
                continue
            }
            for worktree in listing.worktrees where !configured.contains(worktree.path.standardizedFileURL) {
                rows.append(.worktree(worktree, parent: workspace))
            }
        }
        return rows
    }

    override func numberOfRows() -> Int { rows.count }

    /// Highlight the first workspace (so Enter opens it), not the pinned ＋ row; fall back to the
    /// ＋ row when there are no workspaces (or no filter matches).
    override func defaultSelectionIndex() -> Int {
        rows.firstIndex { if case .workspace = $0 { return true } else { return false } } ?? 0
    }

    override func makeRow(at index: Int) -> PaletteRowView {
        switch rows[index] {
        case .add:
            return AddRowView()
        case .workspace(let workspace):
            return RowView(workspace: workspace)
        case .worktree(let worktree, let parent):
            guard !removals.isRemoving(worktree.path) else { return RemovingRowView(worktree: worktree) }
            return RowView(worktree: worktree, parent: parent)
        }
    }

    override func isSelectable(at index: Int) -> Bool {
        guard case .worktree(let worktree, _) = rows[index] else { return true }
        return !removals.isRemoving(worktree.path)
    }

    /// A confirm shown over the list, which stays put underneath it. Removing a worktree is
    /// answered here rather than by replacing the picker: the row it is about has to remain
    /// visible, and it becomes the progress state the moment the answer is yes.
    private var confirmCard: ConfirmCard?

    override var isShowingOverlaidCard: Bool { confirmCard != nil }

    func presentConfirm(_ card: ConfirmCard) {
        confirmCard?.removeFromSuperview()
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        confirmCard = card
        card.focusInitialResponder()
        card.animateIn()
    }

    /// While a card is up the keyboard is its own, so focus goes there rather than to the query.
    override func focusInitialResponder() {
        if let confirmCard { confirmCard.focusInitialResponder() } else { focusQuery() }
    }

    /// Take the confirm down and give the list its keyboard back. The slot is cleared in the exit
    /// animation's completion, not before it: the card is on screen for that whole spring, and
    /// releasing it early hands Esc back to the picker, which closes the picker instead.
    func dismissConfirm() {
        guard let card = confirmCard else { return }
        card.animateOut { [weak self, weak card] in
            card?.removeFromSuperview()
            guard let self, self.confirmCard === card else { return }
            self.confirmCard = nil
        }
        focusQuery()
    }

    override func reapplyTheme() {
        super.reapplyTheme()
        confirmCard?.reapplyTheme()
    }

    #if DEBUG
        var presentedConfirmForTesting: ConfirmCard? { confirmCard }
    #endif

    /// Re-render around a removal that started or finished. Rebuilt rather than restyled: the row
    /// changes type, and the identity carries the removal so a stale view is never reused.
    func refreshRemovalState() {
        let held = rows.indices.contains(selected) ? rowIdentity(at: selected) : nil
        applyFilter(query: currentQuery)
        refreshRows(animated: true)
        reselect(byIdentity: held)
    }

    /// A row is the same row across a re-filter when it's the ＋ row or names the same workspace.
    /// Workspace titles are the `[Title]` section headers, unique by construction, and a row renders
    /// nothing but the title and its branch (which updates in place rather than by rebuilding).
    override func rowIdentity(at index: Int) -> AnyHashable? {
        switch rows[index] {
        case .add: return ["add"]
        case .workspace(let workspace): return ["workspace", workspace.title]
        // The path, not the branch: a worktree's branch changes under it, and a reused row keeps
        // whatever it baked in at construction. The removal state rides along for the same reason:
        // a row that has started removing is a different view, so it must not reuse the old one.
        case .worktree(let worktree, _):
            return ["worktree", worktree.path.path, removals.isRemoving(worktree.path) ? "removing" : ""]
        }
    }

    /// A workspace survives the filter when its own title matches or one of its worktrees does, so
    /// a query naming a branch never renders that worktree's row orphaned. A title match keeps the
    /// whole group; a worktree-only match narrows the group to the worktrees that matched.
    override func applyFilter(query: String) {
        let q = query.lowercased()
        guard !q.isEmpty else {
            // The ＋ row stays pinned at the top through any filter.
            rows = Self.rows(
                for: entries, listings: listings, configured: configuredPaths, owners: worktreeOwners)
            return
        }

        var matches: [Workspace] = []
        var narrowed: [URL: WorktreeListing] = [:]
        for workspace in entries {
            let path = workspace.path.standardizedFileURL
            let all = listings[path]?.worktrees ?? []
            let titleMatches = workspace.title.lowercased().contains(q)
            let hits = titleMatches ? all : all.filter { Self.matches($0, q) }
            guard titleMatches || !hits.isEmpty else { continue }
            matches.append(workspace)
            narrowed[path] = WorktreeListing(commonDir: listings[path]?.commonDir, worktrees: hits)
        }
        matches.sort { a, b in
            let ap = a.title.lowercased().hasPrefix(q)
            let bp = b.title.lowercased().hasPrefix(q)
            if ap != bp { return ap }  // prefix matches rank first
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        // Owners come from `entries`, never from `matches`: the filter re-sorts, and ownership
        // must not move with it.
        rows = Self.rows(
            for: matches, listings: narrowed, configured: configuredPaths, owners: worktreeOwners)
    }

    /// The head is searched as well as the branch: a detached worktree renders its short head, and
    /// a row you cannot find by the text it shows is a row you cannot find.
    private static func matches(_ worktree: Worktree, _ query: String) -> Bool {
        if let branch = worktree.branch, branch.lowercased().contains(query) { return true }
        if worktree.branch == nil, worktree.head.lowercased().hasPrefix(query) { return true }
        return worktree.path.lastPathComponent.lowercased().contains(query)
    }

    /// The create hint reads the live keymap and drops out when the action is unbound, unlike the
    /// four beside it, which are fixed keys the picker owns.
    static func footerHints() -> [PaletteHint] {
        var hints = [
            PaletteHint(keys: "⏎", label: "open"),
            PaletteHint(keys: "⇧⏎", label: "replace"),
        ]
        if let chord = Chord.displayed(.createWorktree, in: GeneralConfig.current.keymap) {
            hints.append(PaletteHint(keys: chord.displayGlyph, label: "new worktree"))
        }
        if let chord = Chord.displayed(.removeWorktree, in: GeneralConfig.current.keymap) {
            hints.append(PaletteHint(keys: chord.displayGlyph, label: "remove worktree"))
        }
        return hints + [
            PaletteHint(keys: "↑↓", label: "move"),
            PaletteHint(keys: "⎋", label: "close"),
        ]
    }

    /// Two answers, because a worktree row disagrees on them: `repo` is the row's own checkout, so
    /// the base is the branch you can see, while `workspace` is the parent, which holds the install.
    struct CreateTarget: Equatable {
        let workspace: Workspace
        let repo: URL
    }

    var createTarget: CreateTarget? {
        guard rows.indices.contains(selected) else { return nil }
        switch rows[selected] {
        case .add: return nil
        case .workspace(let workspace):
            return CreateTarget(workspace: workspace, repo: workspace.path)
        case .worktree(let worktree, let parent):
            return CreateTarget(workspace: parent, repo: worktree.path)
        }
    }

    /// The selected worktree and the workspace it hangs under, or nil on any other row. The parent
    /// comes along because removing runs `git` in its checkout and its `carry` names what goes with
    /// the folder. A worktree already being removed is unselectable, so it can never be this.
    var selectedWorktree: (worktree: Worktree, parent: Workspace)? {
        guard rows.indices.contains(selected), case .worktree(let worktree, let parent) = rows[selected]
        else { return nil }
        return (worktree, parent)
    }

    override func activate(index: Int, modifiers: NSEvent.ModifierFlags) {
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
        case .add: onAddWorkspace()
        case .workspace(let workspace): onChoose(workspace, modifiers.contains(.shift))
        case .worktree(let worktree, let parent):
            onChoose(Self.workspace(for: worktree, parent: parent), modifiers.contains(.shift))
        }
    }

    /// The parent's recipe, opened in the worktree's folder: same panes, same drawers, same env,
    /// pinned to a tab that names both. A worktree is the project, on another branch.
    static func workspace(for worktree: Worktree, parent: Workspace) -> Workspace {
        // The same fallback the row uses. A detached worktree's folder name is whatever directory
        // it was made in, which reads like a branch and is not one.
        let name = worktree.branch ?? String(worktree.head.prefix(7))
        return Workspace(
            title: "\(parent.title): \(name)", path: worktree.path, main: parent.main,
            right: parent.right, bottom: parent.bottom, focus: parent.focus, env: parent.env,
            carry: parent.carry)
    }

    /// The persistent "＋ New Workspace…" action row. The `＋` is what distinguishes it; the accent
    /// belongs to the selection highlight, so a permanent row wearing it competes with the thing you
    /// actually have selected, and collides outright once the row itself is selected.
    private final class AddRowView: SelectableRowView {
        override init() {
            super.init()

            let icon = NSImageView()
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "add workspace")?
                .withSymbolConfiguration(config)
            icon.contentTintColor = Theme.current.chrome.ink(.muted)
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)

            let label = NSTextField(labelWithString: "New Workspace…")
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = Theme.current.chrome.ink(.muted)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }

    /// A worktree still listed because its folder is still on disk, with its delete running. Not
    /// selectable: opening it would land a tab in a folder being removed underneath it.
    final class RemovingRowView: SelectableRowView {
        /// The worktree this row stands for, by the name the ordinary row would have shown.
        let name: String

        init(worktree: Worktree) {
            name = worktree.branch ?? String(worktree.head.prefix(7))
            super.init()

            let spinner = Spinner()
            spinner.isSpinning = true
            addSubview(spinner)

            let label = NSTextField(labelWithString: "Removing \(name)…")
            label.font = .systemFont(ofSize: 11)
            label.textColor = Theme.current.chrome.ink(.faint)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)

            NSLayoutConstraint.activate([
                spinner.leadingAnchor.constraint(
                    equalTo: leadingAnchor, constant: 11 + RowView.childIndent),
                spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }

    /// One workspace row: title (left) and the branch its dir is on (right) when it is a repo. The
    /// branch label is always built and starts empty — reading `HEAD` is filesystem I/O, which
    /// can't run on the main thread, so the row shows the last-known answer now and
    /// `applyGitStatus()` fills the branch in when a fresh probe lands.
    final class RowView: SelectableRowView {
        /// How much width a branch may take before it truncates. A cap, not a reserved column:
        /// the counts sit against the branch, so reserving the full width would strand a `~1`
        /// 220pt from a row reading `main`. Measured in points rather than characters, which are
        /// proportional and so land somewhere different on every row.
        static let branchMaxWidth: CGFloat = 220

        /// How little branch a row will fall to before the title starts giving way instead. Without
        /// it the branch has the lowest compression resistance in the row and absorbs the whole
        /// squeeze, collapsing to an ellipsis beside a title that never gave an inch.
        static let branchMinWidth: CGFloat = 120

        /// How far a worktree row sits inside its workspace, on top of the row's own inset.
        static let childIndent: CGFloat = 16

        let workspace: Workspace
        /// The worktree this row stands for, or nil on a workspace row.
        let worktree: Worktree?
        /// The folder whose git status this row shows: the worktree's own, not its parent's.
        private let statusPath: URL
        private let branchLabel = NSTextField(labelWithString: "")
        private let churnLabel = NSTextField(labelWithString: "")
        /// Held at `min(the branch's own width, branchMinWidth)`: a floor that a short branch like
        /// `main` never reaches, so it still hugs rather than reserving a column.
        private var branchFloor: NSLayoutConstraint!

        /// Extra width between one glyph-and-count group and the next, on top of the space itself.
        static let groupGap: CGFloat = 4

        /// The counts, in the order and vocabulary a starship prompt writes them, each token in the
        /// chrome role that stands for its color there. Nerd-font glyphs are out: the chrome draws
        /// in the system font, where a private-use codepoint renders as a box.
        static func churnText(_ churn: GitChurn) -> NSAttributedString {
            let chrome = Theme.current.chrome
            let font = NSFont.systemFont(ofSize: 11)
            let out = NSMutableAttributedString()
            func token(_ text: String, _ role: TerminalColor) {
                // A glyph binds to its own count and separates from the next pair, so the eye reads
                // groups rather than one run of symbols. Kerning the gap, rather than padding with
                // more spaces, keeps it under a point of control instead of the font's space width.
                if out.length > 0 {
                    out.append(
                        NSAttributedString(string: " ", attributes: [.font: font, .kern: groupGap]))
                }
                out.append(
                    NSAttributedString(
                        string: text, attributes: [.foregroundColor: role.nsColor, .font: font]))
            }

            if churn.ahead > 0 { token("⇡\(churn.ahead)", chrome.info) }
            if churn.behind > 0 { token("⇣\(churn.behind)", chrome.destructive) }
            if churn.staged > 0 { token("+\(churn.staged)", chrome.positive) }
            if churn.modified > 0 { token("~\(churn.modified)", chrome.warning) }
            if churn.untracked > 0 { token("?\(churn.untracked)", chrome.attention) }
            if churn.renamed > 0 { token("»\(churn.renamed)", chrome.info) }
            if churn.deleted > 0 { token("-\(churn.deleted)", chrome.destructive) }
            if churn.conflicted > 0 { token("≠\(churn.conflicted)", chrome.accent) }
            return out
        }

        /// What the left slot says on a worktree row. It is a type slot, not a name slot: a
        /// worktree has no name, and its two candidates are the branch (which the right column
        /// owns) and a folder that is either that branch's slug or a UUID.
        static let typeRail = "Worktree"

        convenience init(workspace: Workspace) {
            self.init(
                workspace: workspace, worktree: nil, label: workspace.title,
                statusPath: workspace.path, indent: 0)
        }

        /// A worktree of `parent`'s repo, indented under the workspace row it belongs to. Its
        /// branch goes where every other row's branch goes, so one column means one thing at
        /// every depth, and the left says what kind of row this is instead.
        convenience init(worktree: Worktree, parent: Workspace) {
            self.init(
                workspace: parent, worktree: worktree, label: Self.typeRail,
                statusPath: worktree.path, indent: Self.childIndent)
        }

        private init(
            workspace: Workspace, worktree: Worktree?, label: String, statusPath: URL,
            indent: CGFloat
        ) {
            self.workspace = workspace
            self.worktree = worktree
            self.statusPath = statusPath
            super.init()

            // The rail is a type, not a name, so it is quieter and smaller than one. That is also
            // what makes a child recede without spending an ink step on it.
            let name = NSTextField(labelWithString: label)
            name.font = .systemFont(ofSize: worktree == nil ? 13 : 11)
            name.textColor =
                worktree == nil
                ? Theme.current.chrome.foreground.nsColor : Theme.current.chrome.ink(.faint)
            name.lineBreakMode = .byTruncatingTail
            name.translatesAutoresizingMaskIntoConstraints = false
            addSubview(name)

            branchLabel.font = .systemFont(ofSize: 11)
            branchLabel.textColor = Theme.current.chrome.ink(.muted)
            branchLabel.alignment = .right
            branchLabel.lineBreakMode = .byTruncatingTail
            // Hug the text: the branch takes the width it needs up to the cap, so the counts sit
            // against it rather than against a reserved column edge.
            branchLabel.setContentHuggingPriority(.required, for: .horizontal)
            branchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            branchLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(branchLabel)

            churnLabel.alignment = .right
            churnLabel.lineBreakMode = .byClipping
            // The counts arrive as an attributed value, which carries its own line behaviour, so
            // the field's own setting does not reach them. See docs/swift-conventions.md.
            churnLabel.maximumNumberOfLines = 1
            churnLabel.setContentHuggingPriority(.required, for: .horizontal)
            // Above the title's 750 so the counts are the last thing to give, but breakable, so a
            // row too narrow for everything still lays out.
            churnLabel.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
            churnLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(churnLabel)

            // The floor is a preference, not a law: a narrow tile can leave less room than the
            // floor plus the counts plus a gap, and three required constraints in that row would
            // go unsatisfiable rather than degrade.
            branchFloor = branchLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
            branchFloor.priority = .defaultHigh

            NSLayoutConstraint.activate([
                name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10 + indent),
                name.centerYAnchor.constraint(equalTo: centerYAnchor),
                branchLabel.widthAnchor.constraint(
                    lessThanOrEqualToConstant: Self.branchMaxWidth),
                branchFloor,
                branchLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                branchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                churnLabel.trailingAnchor.constraint(
                    equalTo: branchLabel.leadingAnchor, constant: -10),
                churnLabel.leadingAnchor.constraint(
                    greaterThanOrEqualTo: name.trailingAnchor, constant: 12),
                churnLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            applyGitStatus()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// Show the branch when this workspace's folder is a known repo. Run at build time and
        /// again whenever a `GitRepoStatus.refresh` lands.
        /// A detached worktree's head is a commit, and announcing it as a branch tells a screen
        /// reader the repository is in a state it is not in.
        static func headDescription(_ head: String, _ worktree: Worktree?) -> String {
            guard let worktree else { return "on branch \(head)" }
            return worktree.branch == nil
                ? "worktree with a detached head at \(head)" : "worktree on branch \(head)"
        }

        func applyGitStatus() {
            // One rule at every depth: churn, then the head. A worktree's branch comes from the
            // listing that named it; only a workspace waits on a probe. Nothing probes a worktree
            // path for churn yet, so that half of a child row is a reserved slot, not a value.
            let head =
                worktree.map { $0.branch ?? String($0.head.prefix(7)) }
                ?? GitRepoStatus.branch(statusPath)
            branchLabel.stringValue = head ?? ""
            branchLabel.setAccessibilityLabel(head.map { Self.headDescription($0, worktree) })
            branchFloor.constant = min(
                branchLabel.intrinsicContentSize.width, Self.branchMinWidth)

            let churn = GitRepoStatus.churn(statusPath) ?? GitChurn()
            churnLabel.attributedStringValue = Self.churnText(churn)
        }
    }
}
