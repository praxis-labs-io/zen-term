import AppKit

/// The `⌘⇧P` project picker: a modal palette over the tab's tile region listing the
/// workspaces configured in `~/.config/zen-term/workspaces`. Enter opens the selected
/// workspace in a new tab, Shift+Enter replaces the current tab, Esc / backdrop click
/// dismiss. Built on `PaletteOverlay`, which owns the card/list/keyboard scaffolding;
/// this supplies the workspace rows + filter.
final class RepoPickerOverlay: PaletteOverlay {
    /// (selected workspace, replaceCurrentTab). `replaceCurrentTab` is Shift+Enter.
    private let onChoose: (Workspace, Bool) -> Void

    private let entries: [Workspace]
    private var filtered: [Workspace]

    init(
        entries: [Workspace], background: NSColor,
        onChoose: @escaping (Workspace, Bool) -> Void, onDismiss: @escaping () -> Void
    ) {
        self.entries = entries
        self.filtered = entries
        self.onChoose = onChoose
        super.init(
            background: background,
            placeholder: "Search projects…",
            emptyText: "No projects yet — add one in ~/.config/zen-term/workspaces",
            footerHints: [
                PaletteHint(keys: "⏎", label: "new tab"),
                PaletteHint(keys: "⇧⏎", label: "replace"),
                PaletteHint(keys: "↑↓", label: "move"),
                PaletteHint(keys: "⎋", label: "close"),
            ],
            rowHeight: 32,
            onDismiss: onDismiss)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func numberOfRows() -> Int { filtered.count }

    override func makeRow(at index: Int) -> PaletteRowView {
        RowView(workspace: filtered[index]) { [weak self] clickCount in
            self?.selectRow(at: index, clickCount: clickCount)
        }
    }

    override func applyFilter(query: String) {
        let q = query.lowercased()
        if q.isEmpty {
            filtered = entries
        } else {
            filtered =
                entries
                .filter { $0.title.lowercased().contains(q) }
                .sorted { a, b in
                    let ap = a.title.lowercased().hasPrefix(q)
                    let bp = b.title.lowercased().hasPrefix(q)
                    if ap != bp { return ap }  // prefix matches rank first
                    return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
                }
        }
    }

    override func activate(index: Int, modifiers: NSEvent.ModifierFlags) {
        guard filtered.indices.contains(index) else { return }
        onChoose(filtered[index], modifiers.contains(.shift))
    }

    /// One workspace row: title (left) and a muted git icon (right) when its dir is a repo.
    private final class RowView: SelectableRowView {
        init(workspace: Workspace, onClick: @escaping (Int) -> Void) {
            super.init(onClick: onClick)

            let name = NSTextField(labelWithString: workspace.title)
            name.font = .systemFont(ofSize: 13)
            name.textColor = Theme.current.chrome.foreground.nsColor
            name.translatesAutoresizingMaskIntoConstraints = false
            addSubview(name)
            NSLayoutConstraint.activate([
                name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                name.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])

            if GitRepo.isGitRepo(workspace.path) {
                let git = NSImageView()
                let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                git.image = NSImage(
                    systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "git repository")?
                    .withSymbolConfiguration(config)
                git.contentTintColor = Theme.current.chrome.ink(alpha: 0.35)
                git.translatesAutoresizingMaskIntoConstraints = false
                addSubview(git)
                git.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14).isActive = true
                git.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }
}
