import AppKit

/// The `⌘⇧P` repo picker: a modal palette over the tab's tile region listing the
/// directories under `~/dev`. Enter opens the selected repo in a new tab, Shift+Enter
/// replaces the current tab, Esc / backdrop click dismiss. Built on `PaletteOverlay`,
/// which owns the card/list/keyboard scaffolding; this supplies the repo rows + filter.
final class RepoPickerOverlay: PaletteOverlay {
    /// (selected directory, replaceCurrentTab). `replaceCurrentTab` is Shift+Enter.
    private let onChoose: (URL, Bool) -> Void

    private let entries: [RepoEntry]
    private var filtered: [RepoEntry]

    init(
        entries: [RepoEntry], background: NSColor,
        onChoose: @escaping (URL, Bool) -> Void, onDismiss: @escaping () -> Void
    ) {
        self.entries = entries
        self.filtered = entries
        self.onChoose = onChoose
        super.init(
            background: background,
            placeholder: "Search ~/dev…",
            emptyText: "No directories in ~/dev",
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
        RowView(entry: filtered[index]) { [weak self] clickCount in
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
                .filter { $0.name.lowercased().contains(q) }
                .sorted { a, b in
                    let ap = a.name.lowercased().hasPrefix(q)
                    let bp = b.name.lowercased().hasPrefix(q)
                    if ap != bp { return ap }  // prefix matches rank first
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
        }
    }

    override func activate(index: Int, modifiers: NSEvent.ModifierFlags) {
        guard filtered.indices.contains(index) else { return }
        onChoose(filtered[index].url, modifiers.contains(.shift))
    }

    /// One directory row: name (left) and a muted git icon (right) when it's a repo.
    private final class RowView: SelectableRowView {
        init(entry: RepoEntry, onClick: @escaping (Int) -> Void) {
            super.init(onClick: onClick)

            let name = NSTextField(labelWithString: entry.name)
            name.font = .systemFont(ofSize: 13)
            name.textColor = Theme.current.chrome.foreground.nsColor
            name.translatesAutoresizingMaskIntoConstraints = false
            addSubview(name)
            NSLayoutConstraint.activate([
                name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                name.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])

            if entry.isGitRepo {
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
