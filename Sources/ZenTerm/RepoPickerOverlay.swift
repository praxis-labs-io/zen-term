import AppKit

/// The `⌘P` workspace picker: a modal palette over the tab's tile region listing the
/// workspaces configured in `~/.config/zen-term/workspaces`, led by a persistent
/// "＋ New Workspace…" row that opens the Add-Workspace form. Enter opens the selected workspace in
/// a new tab, Shift+Enter replaces the current tab, Esc / backdrop click dismiss. Built on
/// `PaletteOverlay`, which owns the card/list/keyboard scaffolding; this supplies the rows + filter.
final class RepoPickerOverlay: PaletteOverlay {
    /// A leading action row, then each workspace followed by its own clones and any still being
    /// made.
    private enum Row {
        case add
        case workspace(Workspace)
        case clone(Clone, parent: Workspace)
        case pendingClone(id: UUID, parent: Workspace)
    }

    /// A clone `CloneStore.create` is still working on: a placeholder row under `parent` until
    /// `completePendingClone`/`failPendingClone` resolves it.
    private struct PendingClone {
        let id: UUID
        let parent: Workspace
    }

    /// (selected workspace, replaceCurrentTab). `replaceCurrentTab` is Shift+Enter.
    private let onChoose: (Workspace, Bool) -> Void
    /// Open the Add-Workspace form (the ＋ row, and the empty state when there are no workspaces).
    private let onAddWorkspace: () -> Void

    private let entries: [Workspace]
    private var clones: [Clone]
    private var pending: [PendingClone] = []
    private var rows: [Row]

    init(
        entries: [Workspace], clones: [Clone], background: NSColor,
        onChoose: @escaping (Workspace, Bool) -> Void, onAddWorkspace: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.entries = entries
        self.clones = clones
        self.rows = Self.rows(for: entries, clones: clones, pending: [])
        self.onChoose = onChoose
        self.onAddWorkspace = onAddWorkspace
        super.init(
            background: background,
            placeholder: "Search workspaces…",
            emptyText: "",  // never shown — the ＋ row is always present, so the list is never empty
            footerHints: [
                PaletteHint(keys: "⏎", label: "open"),
                PaletteHint(keys: "⇧⏎", label: "replace"),
                PaletteHint(keys: "⌥⏎", label: "clone"),
                PaletteHint(keys: "⎋", label: "close"),
            ],
            rowHeight: 32,
            onDismiss: onDismiss)

        // One background pass per open: the rows are up with whatever git status was already known,
        // and the badges fill in when the probes land. Per open rather than once per process, so a
        // folder that just became a repo gets its badge without a relaunch.
        GitRepoStatus.refresh(entries.map(\.path)) { [weak self] in self?.applyGitStatus() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Re-read every workspace row's badge from `GitRepoStatus`.
    private func applyGitStatus() {
        for row in rowViews { (row as? RowView)?.applyGitStatus() }
    }

    /// The ＋ row first, then each workspace trailed by the clones made from it and, last, any
    /// still being made.
    private static func rows(for workspaces: [Workspace], clones: [Clone], pending: [PendingClone])
        -> [Row]
    {
        [.add]
            + workspaces.flatMap { workspace in
                [Row.workspace(workspace)]
                    + clones.filter { $0.workspaceTitle == workspace.title }
                    .map { Row.clone($0, parent: workspace) }
                    + pending.filter { $0.parent.title == workspace.title }
                    .map { Row.pendingClone(id: $0.id, parent: workspace) }
            }
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
        case .clone(let clone, _):
            return CloneRowView(clone: clone)
        case .pendingClone:
            return PendingCloneRowView()
        }
    }

    /// A row is the same row across a re-filter when it's the ＋ row or names the same workspace.
    /// Workspace titles are the `[Title]` section headers, unique by construction, and a row renders
    /// nothing but the title and a git badge (which updates in place rather than by rebuilding).
    override func rowIdentity(at index: Int) -> AnyHashable? {
        switch rows[index] {
        case .add: return ["add"]
        case .workspace(let workspace): return ["workspace", workspace.title]
        case .clone(let clone, _): return ["clone", clone.workspaceTitle, clone.name]
        case .pendingClone(let id, _): return ["pendingClone", id.uuidString]
        }
    }

    /// A clone still being made can't be opened yet — skip it in arrow nav and clicks, the same
    /// treatment a section header gets.
    override func isSelectable(at index: Int) -> Bool {
        if case .pendingClone = rows[index] { return false }
        return true
    }

    /// Filter on workspace titles, and keep a workspace whose clone matches: a clone is a child of
    /// its parent row, so hiding the parent would orphan it.
    override func applyFilter(query: String) {
        let q = query.lowercased()
        let matches: [Workspace]
        if q.isEmpty {
            matches = entries
        } else {
            matches =
                entries
                .filter { workspace in
                    workspace.title.lowercased().contains(q)
                        || clones.contains {
                            $0.workspaceTitle == workspace.title && $0.title.lowercased().contains(q)
                        }
                }
                .sorted { a, b in
                    let ap = a.title.lowercased().hasPrefix(q)
                    let bp = b.title.lowercased().hasPrefix(q)
                    if ap != bp { return ap }  // prefix matches rank first
                    return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
                }
        }
        // the ＋ row stays pinned at the top through any filter
        rows = Self.rows(for: matches, clones: clones, pending: pending)
    }

    override func activate(index: Int, modifiers: NSEvent.ModifierFlags) {
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
        case .add: onAddWorkspace()
        case .workspace(let workspace): onChoose(workspace, modifiers.contains(.shift))
        case .clone(let clone, let parent):
            onChoose(clone.workspace(from: parent), modifiers.contains(.shift))
        case .pendingClone:
            break  // not selectable; nothing to activate yet
        }
    }

    /// The workspace under the current selection, or nil when a clone, a clone still being made,
    /// or the ＋ row is selected. `WindowController` reads this to resolve ⌥⏎ into "clone this
    /// row", without the picker needing its own copy of that chord's handling.
    var selectedWorkspace: Workspace? {
        guard rows.indices.contains(selected), case .workspace(let workspace) = rows[selected] else {
            return nil
        }
        return workspace
    }

    /// Insert a placeholder row under `workspace` immediately, before the clone itself exists.
    /// Resolve it with `completePendingClone`/`failPendingClone` once `CloneStore.create` returns.
    @discardableResult
    func beginPendingClone(for workspace: Workspace) -> UUID {
        let id = UUID()
        pending.append(PendingClone(id: id, parent: workspace))
        rebuildRows()
        return id
    }

    /// Swap a pending row for the real clone row. The picker stays open — opening it is a
    /// separate ⏎/⇧⏎, the same as any other row.
    func completePendingClone(_ id: UUID, with clone: Clone) {
        pending.removeAll { $0.id == id }
        clones.append(clone)
        rebuildRows()
    }

    /// Drop a pending row whose clone failed. `WindowController` shows the failure toast
    /// separately; this only clears the placeholder.
    func failPendingClone(_ id: UUID) {
        pending.removeAll { $0.id == id }
        rebuildRows()
    }

    /// Re-derive `rows` under whatever the user has currently typed and re-render, for a change
    /// that isn't itself a filter edit (a pending clone starting, finishing, or failing).
    /// A reload resets selection to the default, which is right for a filter edit and wrong
    /// here: cloning row 5 must not bounce the user back to row 1. Carry the current row's
    /// identity across the rebuild and reselect it if it's still there.
    private func rebuildRows() {
        let identity = rows.indices.contains(selected) ? rowIdentity(at: selected) : nil
        applyFilter(query: currentQuery)
        refreshRows()
        reselect(byIdentity: identity)
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

    /// One clone row: indented under its parent, with the branch it sits on trailing. The indent
    /// and the turn glyph carry the parent relationship; the branch is what tells two clones apart.
    final class CloneRowView: SelectableRowView {
        let clone: Clone

        init(clone: Clone) {
            self.clone = clone
            super.init()

            let glyph = NSImageView()
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            glyph.image = NSImage(
                systemSymbolName: "arrow.turn.down.right", accessibilityDescription: "clone")?
                .withSymbolConfiguration(config)
            glyph.contentTintColor = Theme.current.chrome.ink(.faint)
            glyph.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glyph)

            let name = NSTextField(labelWithString: clone.title)
            name.font = .systemFont(ofSize: 13)
            name.textColor = Theme.current.chrome.foreground.nsColor
            name.translatesAutoresizingMaskIntoConstraints = false
            addSubview(name)

            let branch = NSTextField(labelWithString: clone.branch)
            branch.font = .systemFont(ofSize: 11)
            branch.textColor = Theme.current.chrome.ink(.muted)
            branch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            branch.translatesAutoresizingMaskIntoConstraints = false
            addSubview(branch)

            NSLayoutConstraint.activate([
                glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
                glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
                name.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8),
                name.centerYAnchor.constraint(equalTo: centerYAnchor),
                branch.leadingAnchor.constraint(
                    greaterThanOrEqualTo: name.trailingAnchor, constant: 12),
                branch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                branch.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }

    /// A clone `CloneStore.create` hasn't finished yet: the same indent as a real clone row, a
    /// spinner standing in for the branch it doesn't have. `isSelectable(at:)` keeps it out of
    /// arrow nav and clicks, so it never needs to answer ⏎/⇧⏎.
    final class PendingCloneRowView: SelectableRowView {
        override init() {
            super.init()

            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            addSubview(spinner)

            let name = NSTextField(labelWithString: "Cloning…")
            name.font = .systemFont(ofSize: 13)
            name.textColor = Theme.current.chrome.ink(.muted)
            name.translatesAutoresizingMaskIntoConstraints = false
            addSubview(name)

            NSLayoutConstraint.activate([
                spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
                name.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
                name.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }

    /// One workspace row: title (left) and a muted git icon (right) when its dir is a repo. The
    /// badge is always built and starts hidden — whether the folder is a repo is filesystem I/O,
    /// which can't run on the main thread, so the row shows the last-known answer now and
    /// `applyGitStatus()` turns the badge on when a fresh probe lands.
    final class RowView: SelectableRowView {
        let workspace: Workspace
        private let gitBadge = NSImageView()

        init(workspace: Workspace) {
            self.workspace = workspace
            super.init()

            let name = NSTextField(labelWithString: workspace.title)
            name.font = .systemFont(ofSize: 13)
            name.textColor = Theme.current.chrome.foreground.nsColor
            name.translatesAutoresizingMaskIntoConstraints = false
            addSubview(name)

            gitBadge.image = IconCatalog.gitBadge()
            gitBadge.setAccessibilityLabel("git repository")
            gitBadge.contentTintColor = Theme.current.chrome.ink(.faint)
            gitBadge.translatesAutoresizingMaskIntoConstraints = false
            addSubview(gitBadge)

            NSLayoutConstraint.activate([
                name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                name.centerYAnchor.constraint(equalTo: centerYAnchor),
                gitBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                gitBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            applyGitStatus()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        /// Show the badge when this workspace's folder is a known repo. Run at build time and again
        /// whenever a `GitRepoStatus.refresh` lands.
        func applyGitStatus() {
            gitBadge.isHidden = GitRepoStatus.known(workspace.path) != true
        }
    }
}
