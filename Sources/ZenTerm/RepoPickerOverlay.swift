import AppKit
import TerminalKit

final class RepoPickerOverlay: PaletteOverlay {
    private enum Row {
        case add
        case workspace(Workspace)
        case worktree(Worktree, parent: Workspace)
    }

    private let onChoose: (Workspace) -> Void
    private let isOpen: (URL) -> Bool
    private let onAddWorkspace: () -> Void

    private let entries: [Workspace]
    private var listings: [URL: WorktreeListing] = [:]

    /// Cancelled per picker, not queue-wide: another window's picker shares the queue.
    private var churnRefreshes: [GitRepoStatus.RefreshToken] = []
    private var churnProbed: Set<URL>
    private var worktreeRefresh: GitRepoStatus.RefreshToken?
    private var worktreeOwners: [URL: URL] = [:]
    private let configuredPaths: Set<URL>
    private var rows: [Row]
    private let removals: WorktreeRemovalTracker

    init(
        entries: [Workspace], background: NSColor,
        removals: WorktreeRemovalTracker = WorktreeRemovalTracker(),
        isOpen: @escaping (URL) -> Bool = { _ in false },
        onChoose: @escaping (Workspace) -> Void, onAddWorkspace: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.entries = entries
        self.removals = removals
        self.configuredPaths = Set(entries.map { $0.path.standardizedFileURL })
        self.churnProbed = configuredPaths
        self.rows = Self.rows(for: entries, listings: [:], configured: [], owners: [:])
        self.onChoose = onChoose
        self.isOpen = isOpen
        self.onAddWorkspace = onAddWorkspace
        super.init(
            background: background,
            placeholder: "Search workspaces…",
            emptyText: "",
            footerHints: Self.footerHints(),
            rowHeight: 32,
            onDismiss: onDismiss)

        GitRepoStatus.refresh(entries.map(\.path)) { [weak self] in self?.applyGitStatus() }
        refreshChurn(Array(configuredPaths))
        relistWorktrees()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func relistWorktrees() {
        worktreeRefresh?.cancel()
        worktreeRefresh = GitRepoStatus.refreshWorktrees(entries.map(\.path)) {
            [weak self] path, listing in
            self?.setWorktrees(listing, for: path)
        }
    }

    deinit {
        for token in churnRefreshes { token.cancel() }
        worktreeRefresh?.cancel()
    }

    private func refreshChurn(_ paths: [URL]) {
        guard !paths.isEmpty else { return }
        churnRefreshes.append(
            GitRepoStatus.refreshChurn(paths) { [weak self] in self?.applyGitStatus() })
    }

    private func applyGitStatus() {
        for row in rowViews { (row as? RowView)?.applyGitStatus() }
    }

    func setWorktrees(_ listing: WorktreeListing, for workspacePath: URL) {
        listings[workspacePath.standardizedFileURL] = listing
        let unprobed = listing.worktrees.map(\.path.standardizedFileURL).filter {
            churnProbed.insert($0).inserted
        }
        refreshChurn(unprobed)
        worktreeOwners = Self.owners(among: entries, listings: listings)
        let held = rows.indices.contains(selected) ? rowIdentity(at: selected) : nil
        applyFilter(query: currentQuery)
        refreshRows(animated: true)
        reselect(byIdentity: held)
    }

    /// Decided from config order, never the filtered list, so a query can't move a worktree to another parent.
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

    override func defaultSelectionIndex() -> Int {
        rows.firstIndex { if case .workspace = $0 { return true } else { return false } } ?? 0
    }

    override func makeRow(at index: Int) -> PaletteRowView {
        switch rows[index] {
        case .add:
            return AddRowView()
        case .workspace(let workspace):
            return RowView(workspace: workspace, isOpen: isOpen(workspace.path))
        case .worktree(let worktree, let parent):
            guard !removals.isRemoving(worktree.path) else { return RemovingRowView(worktree: worktree) }
            let opens = Self.workspace(for: worktree, parent: parent, repoRoot: GitRepoStatus.repoRoot(parent.path))
            return RowView(worktree: worktree, parent: parent, isOpen: isOpen(opens.path))
        }
    }

    override func isSelectable(at index: Int) -> Bool {
        guard case .worktree(let worktree, _) = rows[index] else { return true }
        return !removals.isRemoving(worktree.path)
    }

    private lazy var confirm = ConfirmSlot(over: self)

    override var isShowingOverlaidCard: Bool { confirm.isShowing }

    func presentConfirm(_ card: ConfirmCard) { confirm.present(card) }

    override func focusInitialResponder() {
        if let card = confirm.card { card.focusInitialResponder() } else { focusQuery() }
    }

    func dismissConfirm() {
        confirm.dismiss { [weak self] in self?.focusQuery() }
    }

    override func reapplyTheme() {
        super.reapplyTheme()
        confirm.card?.reapplyTheme()
    }

    #if DEBUG
        var presentedConfirmForTesting: ConfirmCard? { confirm.card }
    #endif

    func dropWorktree(at path: URL) {
        let target = path.standardizedFileURL
        for (workspace, listing) in listings {
            listings[workspace] = WorktreeListing(
                commonDir: listing.commonDir,
                worktrees: listing.worktrees.filter { $0.path.standardizedFileURL != target })
        }
        worktreeOwners = Self.owners(among: entries, listings: listings)
        refreshRemovalState()
    }

    func refreshRemovalState() {
        let held = rows.indices.contains(selected) ? rowIdentity(at: selected) : nil
        applyFilter(query: currentQuery)
        refreshRows(animated: true)
        reselect(byIdentity: held)
    }

    override func rowIdentity(at index: Int) -> AnyHashable? {
        switch rows[index] {
        case .add: return ["add"]
        case .workspace(let workspace): return ["workspace", workspace.title]
        case .worktree(let worktree, _):
            return ["worktree", worktree.path.path, removals.isRemoving(worktree.path) ? "removing" : ""]
        }
    }

    override func applyFilter(query: String) {
        let q = query.lowercased()
        guard !q.isEmpty else {
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
            if ap != bp { return ap }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        rows = Self.rows(
            for: matches, listings: narrowed, configured: configuredPaths, owners: worktreeOwners)
    }

    private static func matches(_ worktree: Worktree, _ query: String) -> Bool {
        if let branch = worktree.branch, branch.lowercased().contains(query) { return true }
        if worktree.branch == nil, worktree.head.lowercased().hasPrefix(query) { return true }
        return worktree.path.lastPathComponent.lowercased().contains(query)
    }

    static func footerHints() -> [PaletteHint] {
        var hints = [PaletteHint(keys: "⏎", label: "open")]
        if let chord = Chord.displayed(.createWorktree, in: GeneralConfig.current.keymap) {
            hints.append(PaletteHint(keys: chord.displayGlyph, label: "new worktree"))
        }
        if let chord = Chord.displayed(.removeWorktree, in: GeneralConfig.current.keymap) {
            hints.append(PaletteHint(keys: chord.displayGlyph, label: "remove worktree"))
        }
        return hints
    }

    override func selectionChanged() {
        setFooterHint("new worktree", isShown: createTarget != nil)
        setFooterHint("remove worktree", isShown: selectedWorktree != nil)
    }

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

    var selectedWorktree: (worktree: Worktree, parent: Workspace)? {
        guard rows.indices.contains(selected), case .worktree(let worktree, let parent) = rows[selected]
        else { return nil }
        return (worktree, parent)
    }

    override func activate(index: Int, modifiers: NSEvent.ModifierFlags) {
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
        case .add: onAddWorkspace()
        case .workspace(let workspace): onChoose(workspace)
        case .worktree(let worktree, let parent):
            onChoose(
                Self.workspace(for: worktree, parent: parent, repoRoot: GitRepoStatus.repoRoot(parent.path)))
        }
    }

    /// A worktree is cut at the repo root, so a parent pointing into the repo opens at its own folder inside it.
    static func workspace(for worktree: Worktree, parent: Workspace, repoRoot: URL?) -> Workspace {
        let name = worktree.branch ?? String(worktree.head.prefix(7))
        return Workspace(
            title: "\(parent.title): \(name)",
            path: GitRepo.mirrored(parent.path, from: repoRoot, into: worktree.path)
                ?? worktree.path.standardizedFileURL,
            main: parent.main, right: parent.right, bottom: parent.bottom, focus: parent.focus,
            env: parent.env, carry: parent.carry)
    }

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

    final class RemovingRowView: SelectableRowView {
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

    /// The branch fills in later: reading `HEAD` is filesystem I/O and can't run on the main thread.
    final class RowView: SelectableRowView {
        static let branchMaxWidth: CGFloat = 220

        static let branchMinWidth: CGFloat = 120

        static let childIndent: CGFloat = 16

        let workspace: Workspace
        let worktree: Worktree?
        private let statusPath: URL
        private let branchLabel = NSTextField(labelWithString: "")
        private let churnLabel = NSTextField(labelWithString: "")
        private var branchFloor: NSLayoutConstraint!

        static func churnText(_ churn: GitChurn) -> NSAttributedString {
            let chrome = Theme.current.chrome
            func token(_ text: String, _ role: TerminalColor) -> NSAttributedString {
                NSAttributedString(
                    string: text, attributes: [.foregroundColor: role.nsColor, .font: StatusTokens.font])
            }
            var groups: [NSAttributedString] = []
            if churn.ahead > 0 { groups.append(token("⇡\(churn.ahead)", chrome.info)) }
            if churn.behind > 0 { groups.append(token("⇣\(churn.behind)", chrome.destructive)) }
            groups += GitStatusCategory.tokens(counting: churn.count(of:)).map {
                token($0.text, chrome[keyPath: $0.category.role])
            }
            return StatusTokens.joined(groups)
        }

        static let typeRail = "Worktree"

        private static func openMarker(after name: NSView, in row: NSView) -> NSView {
            let marker = NSTextField(labelWithString: "open")
            marker.font = .systemFont(ofSize: 11)
            marker.textColor = Theme.current.chrome.ink(.faint)
            marker.setContentCompressionResistancePriority(.required, for: .horizontal)
            marker.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(marker)
            NSLayoutConstraint.activate([
                marker.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
                marker.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            return marker
        }

        convenience init(workspace: Workspace, isOpen: Bool) {
            self.init(
                workspace: workspace, worktree: nil, label: workspace.title,
                statusPath: workspace.path, indent: 0, isOpen: isOpen)
        }

        convenience init(worktree: Worktree, parent: Workspace, isOpen: Bool) {
            self.init(
                workspace: parent, worktree: worktree, label: Self.typeRail,
                statusPath: worktree.path, indent: Self.childIndent, isOpen: isOpen)
        }

        private init(
            workspace: Workspace, worktree: Worktree?, label: String, statusPath: URL,
            indent: CGFloat, isOpen: Bool
        ) {
            self.workspace = workspace
            self.worktree = worktree
            self.statusPath = statusPath
            super.init()

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
            branchLabel.setContentHuggingPriority(.required, for: .horizontal)
            branchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            branchLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(branchLabel)

            churnLabel.alignment = .right
            churnLabel.lineBreakMode = .byClipping
            churnLabel.maximumNumberOfLines = 1
            churnLabel.setContentHuggingPriority(.required, for: .horizontal)
            churnLabel.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
            churnLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(churnLabel)

            let nameEnd = isOpen ? Self.openMarker(after: name, in: self) : name

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
                    greaterThanOrEqualTo: nameEnd.trailingAnchor, constant: 12),
                churnLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            applyGitStatus()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        static func headDescription(_ head: String, _ worktree: Worktree?) -> String {
            guard let worktree else { return "on branch \(head)" }
            return worktree.branch == nil
                ? "worktree with a detached head at \(head)" : "worktree on branch \(head)"
        }

        func applyGitStatus() {
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
