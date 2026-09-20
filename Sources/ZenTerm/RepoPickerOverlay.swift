import AppKit
import TerminalKit

final class RepoPickerOverlay: PaletteOverlay {
    private enum Row {
        case newWorkspace
        case header(String)
        case open(RunningWorkspace)
        case elsewhere(RunningWorkspace)
        case mutedParent(Workspace)
        case add
        case workspace(Workspace)
        case worktree(Worktree, parent: Workspace)
    }

    private enum Section {
        static let open = "Open"
        static let elsewhere = "Open Elsewhere"
        static let configured = "Configured"
    }

    private let onChoose: (Workspace, WorktreeOrigin?) -> Void
    private let onSwitch: (WorkspaceID) -> Void
    private let onReveal: (Int, WorkspaceID) -> Void
    private let openState: (URL) -> WorkspaceOpenState
    private let onAddWorkspace: () -> Void
    private let onNewWorkspace: () -> Void

    private let entries: [Workspace]
    private let open: [RunningWorkspace]
    private let elsewhere: [RunningWorkspace]
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
        entries: [Workspace], open: [RunningWorkspace] = [], elsewhere: [RunningWorkspace] = [],
        background: NSColor,
        removals: WorktreeRemovalTracker = WorktreeRemovalTracker(),
        openState: @escaping (URL) -> WorkspaceOpenState = { _ in .closed },
        onChoose: @escaping (Workspace, WorktreeOrigin?) -> Void,
        onSwitch: @escaping (WorkspaceID) -> Void = { _ in },
        onReveal: @escaping (Int, WorkspaceID) -> Void = { _, _ in },
        onAddWorkspace: @escaping () -> Void,
        onNewWorkspace: @escaping () -> Void = {}, onDismiss: @escaping () -> Void
    ) {
        self.entries = entries
        self.open = open
        self.elsewhere = elsewhere
        self.removals = removals
        self.configuredPaths = Set(entries.map { $0.path.standardizedFileURL })
        self.churnProbed = configuredPaths
        self.rows = Self.sections(
            open: open, elsewhere: elsewhere, entries: entries, listings: [:], configured: [],
            owners: [:], openState: openState)
        self.onChoose = onChoose
        self.onSwitch = onSwitch
        self.onReveal = onReveal
        self.openState = openState
        self.onAddWorkspace = onAddWorkspace
        self.onNewWorkspace = onNewWorkspace
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

    // A selectable row appears once, and placement reads the rows above rather than `openState`, so
    // nothing falls out of every section. A parent already listed above is redrawn muted where its
    // worktrees sit, because a worktree mirrors its parent's configuration and needs it as a label.
    private static func sections(
        open: [RunningWorkspace], elsewhere: [RunningWorkspace], entries: [Workspace],
        listings: [URL: WorktreeListing], configured: Set<URL>, owners: [URL: URL],
        openState: (URL) -> WorkspaceOpenState
    ) -> [Row] {
        var rows: [Row] = [.newWorkspace]

        if !open.isEmpty {
            rows.append(.header(Section.open))
            rows += open.map(Row.open)
        }

        if !elsewhere.isEmpty {
            rows.append(.header(Section.elsewhere))
            rows += elsewhere.map(Row.elsewhere)
        }

        let listed = Set(
            (open + elsewhere).filter { $0.id != nil }.map { $0.folder.standardizedFileURL })

        rows.append(.header(Section.configured))
        for workspace in entries {
            let isOpen = listed.contains(workspace.path.standardizedFileURL)
            let path = workspace.path.standardizedFileURL
            var children: [Worktree] = []
            if let listing = listings[path], owners[listing.commonDir ?? path] == path {
                children = listing.worktrees.filter {
                    !configured.contains($0.path.standardizedFileURL)
                        && !isListed($0, parent: workspace, among: listed)
                }
            }
            guard !isOpen else {
                if !children.isEmpty { rows.append(.mutedParent(workspace)) }
                rows += children.map { .worktree($0, parent: workspace) }
                continue
            }
            rows.append(.workspace(workspace))
            rows += children.map { .worktree($0, parent: workspace) }
        }
        return rows + [.add]
    }

    // A worktree is cut at the repo root, so the open row sits at the parent's mirrored subfolder inside it.
    private static func isListed(
        _ worktree: Worktree, parent: Workspace, among listed: Set<URL>
    ) -> Bool {
        let mirror = GitRepo.mirrorPath(
            parent.path, from: GitRepoStatus.repoRoot(parent.path), into: worktree.path)
        return listed.contains(worktree.path.standardizedFileURL)
            || listed.contains(mirror.standardizedFileURL)
    }

    // A worktree is cut at the repo root, so it also reads as open when the mirrored subfolder is.
    private static func worktreeOpenState(
        _ worktree: Worktree, parent: Workspace, openState: (URL) -> WorkspaceOpenState
    ) -> WorkspaceOpenState {
        let mirror = GitRepo.mirrorPath(
            parent.path, from: GitRepoStatus.repoRoot(parent.path), into: worktree.path)
        return .strongest([openState(mirror), openState(worktree.path)])
    }

    override func numberOfRows() -> Int { rows.count }

    // New Workspace holds the selection until a query matches something, so a search that finds nothing makes one.
    override func defaultSelectionIndex() -> Int {
        guard !currentQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return 0 }
        return rows.indices.first { index in
            switch rows[index] {
            case .newWorkspace, .add, .header, .mutedParent: return false
            case .open, .elsewhere, .workspace, .worktree: return isSelectable(at: index)
            }
        } ?? 0
    }

    override func makeRow(at index: Int) -> PaletteRowView {
        switch rows[index] {
        case .newWorkspace:
            return ActionRowView(
                symbol: "plus", title: "New Workspace",
                shortcut: Chord.displayed(.newWorkspace, in: GeneralConfig.current.keymap)?.displayGlyph)
        case .add:
            return ActionRowView(symbol: "folder.badge.plus", title: "Add Workspace…", shortcut: nil)
        case .header(let title):
            return PaletteSectionHeader(title: title)
        case .open(let workspace), .elsewhere(let workspace):
            return workspace.id == nil ? RowView(ghost: workspace) : RowView(open: workspace)
        case .mutedParent(let workspace):
            return RowView(mutedParent: workspace)
        case .workspace(let workspace):
            return RowView(workspace: workspace)
        case .worktree(let worktree, let parent):
            guard !removals.isRemoving(worktree.path) else { return RemovingRowView(worktree: worktree) }
            return RowView(worktree: worktree, parent: parent)
        }
    }

    override func rowHeight(at index: Int) -> CGFloat {
        if case .header = rows[index] { return PaletteSectionHeader.height }
        return super.rowHeight(at: index)
    }

    private func openState(row: Row) -> WorkspaceOpenState {
        switch row {
        case .newWorkspace, .add, .header, .mutedParent: return .closed
        case .open: return .here
        case .elsewhere: return .elsewhere
        case .workspace(let workspace): return openState(workspace.path)
        case .worktree(let worktree, let parent):
            return Self.worktreeOpenState(worktree, parent: parent, openState: openState)
        }
    }

    override func isSelectable(at index: Int) -> Bool {
        switch rows[index] {
        case .header, .mutedParent: return false
        case .open(let workspace), .elsewhere(let workspace): return workspace.id != nil
        case .worktree(let worktree, _): return !removals.isRemoving(worktree.path)
        case .newWorkspace, .add, .workspace: return true
        }
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
        case .newWorkspace: return ["new"]
        case .add: return ["add"]
        case .header(let title): return ["header", title]
        case .mutedParent(let workspace): return ["muted", workspace.title]
        case .open(let workspace):
            return ["open", "\(workspace.window)", "\(workspace.id?.raw ?? -1)", workspace.folder.path]
        case .elsewhere(let workspace):
            return [
                "elsewhere", "\(workspace.window)", "\(workspace.id?.raw ?? -1)", workspace.folder.path,
            ]
        case .workspace(let workspace): return ["workspace", workspace.title]
        case .worktree(let worktree, _):
            return ["worktree", worktree.path.path, removals.isRemoving(worktree.path) ? "removing" : ""]
        }
    }

    override func applyFilter(query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            rows = Self.sections(
                open: open, elsewhere: elsewhere, entries: entries, listings: listings,
                configured: configuredPaths, owners: worktreeOwners, openState: openState)
            return
        }

        var scored: [(workspace: Workspace, score: Int)] = []
        var narrowed: [URL: WorktreeListing] = [:]
        for workspace in entries {
            let path = workspace.path.standardizedFileURL
            let all = listings[path]?.worktrees ?? []
            let titleScore = FuzzyMatch.score(q, workspace.title)
            let hits = titleScore != nil ? all : all.filter { Self.score($0, q) != nil }
            guard let score = titleScore ?? hits.compactMap({ Self.score($0, q) }).max() else { continue }
            scored.append((workspace, score))
            narrowed[path] = WorktreeListing(commonDir: listings[path]?.commonDir, worktrees: hits)
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.workspace.title.localizedCaseInsensitiveCompare(b.workspace.title) == .orderedAscending
        }

        rows = Self.sections(
            open: Self.ranked(open, matching: q), elsewhere: Self.ranked(elsewhere, matching: q),
            entries: scored.map(\.workspace), listings: narrowed, configured: configuredPaths,
            owners: worktreeOwners, openState: openState)
    }

    // Ranks the Open section by group, so a worktree never leaves the parent it opened from.
    private static func ranked(
        _ open: [RunningWorkspace], matching query: String
    ) -> [RunningWorkspace] {
        var groups: [(lead: RunningWorkspace, children: [RunningWorkspace])] = []
        for row in open {
            if row.isWorktree, !groups.isEmpty {
                groups[groups.count - 1].children.append(row)
            } else {
                groups.append((row, []))
            }
        }
        return
            groups
            .compactMap { group -> (score: Int, rows: [RunningWorkspace])? in
                let leadScore = group.lead.id == nil ? nil : FuzzyMatch.score(query, group.lead.name)
                let hits =
                    leadScore != nil
                    ? group.children : group.children.filter { FuzzyMatch.score(query, $0.name) != nil }
                guard
                    let score = leadScore
                        ?? hits.compactMap({ FuzzyMatch.score(query, $0.name) }).max()
                else { return nil }
                return (score, [group.lead] + hits)
            }
            .sorted { $0.score > $1.score }
            .flatMap(\.rows)
    }

    private static func score(_ worktree: Worktree, _ query: String) -> Int? {
        var candidates = [worktree.path.lastPathComponent]
        candidates.append(worktree.branch ?? worktree.head)
        return candidates.compactMap { FuzzyMatch.score(query, $0) }.max()
    }

    static func footerHints() -> [PaletteHint] {
        var hints = [PaletteHint(keys: "⏎", label: "open"), PaletteHint(keys: "⏎", label: "switch")]
        if let chord = Chord.displayed(.createWorktree, in: GeneralConfig.current.keymap) {
            hints.append(PaletteHint(keys: chord.displayGlyph, label: "new worktree"))
        }
        if let chord = Chord.displayed(.removeWorktree, in: GeneralConfig.current.keymap) {
            hints.append(PaletteHint(keys: chord.displayGlyph, label: "remove worktree"))
        }
        return hints
    }

    override func selectionChanged() {
        let switches = rows.indices.contains(selected) && openState(row: rows[selected]) != .closed
        setFooterHint("open", isShown: !switches)
        setFooterHint("switch", isShown: switches)
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
        case .newWorkspace, .add, .header, .mutedParent: return nil
        case .open(let row), .elsewhere(let row):
            guard let entry = entries.first(where: { $0.path.standardizedFileURL == row.folder.standardizedFileURL })
            else { return nil }
            return CreateTarget(workspace: entry, repo: entry.path)
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
        case .newWorkspace: onNewWorkspace()
        case .add: onAddWorkspace()
        case .header, .mutedParent: return
        case .open(let row):
            guard let id = row.id else { return }
            onSwitch(id)
        case .elsewhere(let row):
            guard let id = row.id else { return }
            onReveal(row.window, id)
        case .workspace(let workspace): onChoose(workspace, nil)
        case .worktree(let worktree, let parent):
            onChoose(
                Self.workspace(for: worktree, parent: parent, repoRoot: GitRepoStatus.repoRoot(parent.path)),
                WorktreeOrigin(parent: parent, worktree: worktree))
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

    final class ActionRowView: SelectableRowView {
        let title: String

        init(symbol: String, title: String, shortcut: String?) {
            self.title = title
            super.init()

            let icon = NSImageView()
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(config)
            icon.contentTintColor = Theme.current.chrome.ink(.muted)
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)

            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = Theme.current.chrome.ink(.muted)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
                icon.widthAnchor.constraint(equalToConstant: 17),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])

            guard let shortcut else { return }
            let keycap = KeycapView(shortcut: shortcut)
            addSubview(keycap)
            NSLayoutConstraint.activate([
                keycap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: keycap.leadingAnchor, constant: -8),
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
        enum Style {
            case workspace
            case child
            // A group label rather than a listing: the selectable row is closed, or sits in another section.
            case ghost

            var indent: CGFloat { self == .child ? RowView.childIndent : 0 }
            var fontSize: CGFloat { self == .child ? 11 : 13 }
            var ink: NSColor {
                self == .workspace
                    ? Theme.current.chrome.foreground.nsColor : Theme.current.chrome.ink(.faint)
            }
        }

        static let branchMaxWidth: CGFloat = 220

        static let branchMinWidth: CGFloat = 120

        static let childIndent: CGFloat = 16

        let workspace: Workspace?
        let worktree: Worktree?
        let running: RunningWorkspace?
        let style: Style
        let label: String
        private let statusPath: URL?
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

        convenience init(workspace: Workspace) {
            self.init(
                workspace: workspace, worktree: nil, running: nil, label: workspace.title,
                statusPath: workspace.path, style: .workspace)
        }

        convenience init(worktree: Worktree, parent: Workspace) {
            self.init(
                workspace: parent, worktree: worktree, running: nil, label: Self.typeRail,
                statusPath: worktree.path, style: .child)
        }

        convenience init(open: RunningWorkspace) {
            self.init(
                workspace: nil, worktree: nil, running: open,
                label: open.isWorktree ? Self.typeRail : open.name, statusPath: open.folder,
                style: open.isWorktree ? .child : .workspace)
        }

        convenience init(mutedParent: Workspace) {
            self.init(
                workspace: mutedParent, worktree: nil, running: nil, label: mutedParent.title,
                statusPath: nil, style: .ghost)
        }

        convenience init(ghost: RunningWorkspace) {
            self.init(
                workspace: nil, worktree: nil, running: ghost, label: ghost.name, statusPath: nil,
                style: .ghost)
        }

        private init(
            workspace: Workspace?, worktree: Worktree?, running: RunningWorkspace?, label: String,
            statusPath: URL?, style: Style
        ) {
            self.workspace = workspace
            self.worktree = worktree
            self.running = running
            self.style = style
            self.label = label
            self.statusPath = statusPath
            super.init()

            let name = NSTextField(labelWithString: label)
            name.font = .systemFont(ofSize: style.fontSize)
            name.textColor = style.ink
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

            branchFloor = branchLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
            branchFloor.priority = .defaultHigh

            NSLayoutConstraint.activate([
                name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10 + style.indent),
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

        static func headDescription(_ head: String, _ worktree: Worktree?) -> String {
            guard let worktree else { return "on branch \(head)" }
            return worktree.branch == nil
                ? "worktree with a detached head at \(head)" : "worktree on branch \(head)"
        }

        func applyGitStatus() {
            guard let statusPath else { return }
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
