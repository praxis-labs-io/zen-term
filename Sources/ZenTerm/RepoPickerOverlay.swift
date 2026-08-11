import AppKit

/// The `⌘P` workspace picker: a modal palette over the tab's tile region listing the
/// workspaces configured in `~/.config/zen-term/workspaces`, led by a persistent
/// "＋ New Workspace…" row that opens the Add-Workspace form. Enter opens the selected workspace in
/// a new tab, Shift+Enter replaces the current tab, Esc / backdrop click dismiss. Built on
/// `PaletteOverlay`, which owns the card/list/keyboard scaffolding; this supplies the rows + filter.
final class RepoPickerOverlay: PaletteOverlay {
    /// A leading action row, then one row per configured workspace.
    private enum Row {
        case add
        case workspace(Workspace)
    }

    /// (selected workspace, replaceCurrentTab). `replaceCurrentTab` is Shift+Enter.
    private let onChoose: (Workspace, Bool) -> Void
    /// Open the Add-Workspace form (the ＋ row, and the empty state when there are no workspaces).
    private let onAddWorkspace: () -> Void

    private let entries: [Workspace]
    private var rows: [Row]

    init(
        entries: [Workspace], background: NSColor,
        onChoose: @escaping (Workspace, Bool) -> Void, onAddWorkspace: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.entries = entries
        self.rows = Self.rows(for: entries)
        self.onChoose = onChoose
        self.onAddWorkspace = onAddWorkspace
        super.init(
            background: background,
            placeholder: "Search workspaces…",
            emptyText: "",  // never shown — the ＋ row is always present, so the list is never empty
            footerHints: [
                PaletteHint(keys: "⏎", label: "open"),
                PaletteHint(keys: "⇧⏎", label: "replace"),
                PaletteHint(keys: "↑↓", label: "move"),
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

    /// The ＋ row first, then a workspace row per entry.
    private static func rows(for workspaces: [Workspace]) -> [Row] {
        [.add] + workspaces.map(Row.workspace)
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
        }
    }

    /// A row is the same row across a re-filter when it's the ＋ row or names the same workspace.
    /// Workspace titles are the `[Title]` section headers, unique by construction, and a row renders
    /// nothing but the title and a git badge (which updates in place rather than by rebuilding).
    override func rowIdentity(at index: Int) -> AnyHashable? {
        switch rows[index] {
        case .add: return ["add"]
        case .workspace(let workspace): return ["workspace", workspace.title]
        }
    }

    override func applyFilter(query: String) {
        let q = query.lowercased()
        let matches: [Workspace]
        if q.isEmpty {
            matches = entries
        } else {
            matches =
                entries
                .filter { $0.title.lowercased().contains(q) }
                .sorted { a, b in
                    let ap = a.title.lowercased().hasPrefix(q)
                    let bp = b.title.lowercased().hasPrefix(q)
                    if ap != bp { return ap }  // prefix matches rank first
                    return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
                }
        }
        rows = Self.rows(for: matches)  // the ＋ row stays pinned at the top through any filter
    }

    override func activate(index: Int, modifiers: NSEvent.ModifierFlags) {
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
        case .add: onAddWorkspace()
        case .workspace(let workspace): onChoose(workspace, modifiers.contains(.shift))
        }
    }

    /// The persistent "＋ New Workspace…" action row, tinted with the accent so it reads as an
    /// affordance distinct from the workspace list below it.
    private final class AddRowView: SelectableRowView {
        override init() {
            super.init()

            let icon = NSImageView()
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "add workspace")?
                .withSymbolConfiguration(config)
            icon.contentTintColor = Theme.current.chrome.accent.nsColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)

            let label = NSTextField(labelWithString: "New Workspace…")
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = Theme.current.chrome.accent.nsColor
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
            gitBadge.contentTintColor = Theme.current.chrome.ink(alpha: 0.35)
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
