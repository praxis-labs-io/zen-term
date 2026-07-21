import AppKit

/// The diff viewer's base picker: a searchable palette listing the repo's branches, opened from the
/// Committed section header's `main abc1234 ▾` button. The default branch sits on top, the rest by
/// recency (`GitDiffRunner.orderedBranches`); typing filters by substring. Choosing a branch re-runs
/// the committed slice against it. Built on `PaletteOverlay` — the same card/list/keyboard scaffold
/// the workspace picker and command palette use — so it reads as one system. Hosted *inside* the diff
/// viewer (not the window's modal slot), so dismissing it returns to the diff rather than closing it.
final class DiffBasePickerOverlay: PaletteOverlay {
    private let onChoose: (String) -> Void
    /// The base currently driving the committed diff, marked with a check so it reads as the active
    /// one; nil when no base is resolved.
    private let currentBase: String?
    private let branches: [String]
    private var matches: [String]

    init(
        branches: [String], currentBase: String?, background: NSColor,
        onChoose: @escaping (String) -> Void, onDismiss: @escaping () -> Void
    ) {
        self.branches = branches
        self.matches = branches
        self.currentBase = currentBase
        self.onChoose = onChoose
        super.init(
            background: background,
            placeholder: "Compare against…",
            emptyText: "No branches",
            footerHints: [
                PaletteHint(keys: "⏎", label: "compare"),
                PaletteHint(keys: "↑↓", label: "move"),
                PaletteHint(keys: "⎋", label: "close"),
            ],
            rowHeight: 32,
            onDismiss: onDismiss)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Start on the current base so Enter without typing is a no-op-ish reselect, and the eye lands on
    /// what's active; fall back to the first row when the base isn't in the list.
    override func defaultSelectionIndex() -> Int {
        currentBase.flatMap(matches.firstIndex(of:)) ?? 0
    }

    override func numberOfRows() -> Int { matches.count }

    override func makeRow(at index: Int) -> PaletteRowView {
        RowView(branch: matches[index], isCurrent: matches[index] == currentBase) {
            [weak self] clickCount in self?.selectRow(at: index, clickCount: clickCount)
        }
    }

    override func applyFilter(query: String) {
        let q = query.lowercased()
        guard !q.isEmpty else { matches = branches; return }
        matches =
            branches
            .filter { $0.lowercased().contains(q) }
            .sorted { a, b in
                let ap = a.lowercased().hasPrefix(q)
                let bp = b.lowercased().hasPrefix(q)
                if ap != bp { return ap }  // prefix matches rank first
                return false  // otherwise keep the incoming (default-first, then recency) order
            }
    }

    override func activate(index: Int, modifiers: NSEvent.ModifierFlags) {
        guard matches.indices.contains(index) else { return }
        onChoose(matches[index])
    }

    /// The filtered branch names, for tests to assert the search result through the real list.
    var matchesForTesting: [String] { matches }

    /// One branch row: the name (left) and a check (right) on the branch currently being compared
    /// against, so the active base reads at a glance.
    private final class RowView: SelectableRowView {
        init(branch: String, isCurrent: Bool, onClick: @escaping (Int) -> Void) {
            super.init(onClick: onClick)

            let name = NSTextField(labelWithString: branch)
            name.font = .systemFont(ofSize: 13)
            name.lineBreakMode = .byTruncatingMiddle
            name.textColor = Theme.current.chrome.foreground.nsColor
            name.translatesAutoresizingMaskIntoConstraints = false
            addSubview(name)
            NSLayoutConstraint.activate([
                name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                name.centerYAnchor.constraint(equalTo: centerYAnchor),
                name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -34),
            ])

            guard isCurrent else { return }
            let check = NSImageView()
            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "current base")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            check.contentTintColor = Theme.current.chrome.accent.nsColor
            check.translatesAutoresizingMaskIntoConstraints = false
            addSubview(check)
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14).isActive = true
            check.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }
}
