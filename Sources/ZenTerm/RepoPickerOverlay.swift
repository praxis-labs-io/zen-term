import AppKit
import TerminalKit

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
        // and the branches fill in when the probes land. Per open rather than once per process, so
        // a branch switched in a shell shows up without a relaunch.
        GitRepoStatus.refresh(entries.map(\.path)) { [weak self] in self?.applyGitStatus() }
        // The counts run `git` rather than reading a file, so they land after the branch does
        // rather than holding it up.
        GitRepoStatus.refreshChurn(entries.map(\.path)) { [weak self] in self?.applyGitStatus() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Re-read every workspace row's branch from `GitRepoStatus`.
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
    /// nothing but the title and its branch (which updates in place rather than by rebuilding).
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

        let workspace: Workspace
        private let branchLabel = NSTextField(labelWithString: "")
        private let churnLabel = NSTextField(labelWithString: "")

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

        init(workspace: Workspace) {
            self.workspace = workspace
            super.init()

            let name = NSTextField(labelWithString: workspace.title)
            name.font = .systemFont(ofSize: 13)
            name.textColor = Theme.current.chrome.foreground.nsColor
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
            churnLabel.setContentHuggingPriority(.required, for: .horizontal)
            churnLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            churnLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(churnLabel)

            NSLayoutConstraint.activate([
                name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                name.centerYAnchor.constraint(equalTo: centerYAnchor),
                branchLabel.widthAnchor.constraint(
                    lessThanOrEqualToConstant: Self.branchMaxWidth),
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
        func applyGitStatus() {
            let branch = GitRepoStatus.branch(workspace.path)
            branchLabel.stringValue = branch ?? ""
            branchLabel.setAccessibilityLabel(branch.map { "on branch \($0)" })

            let churn = GitRepoStatus.churn(workspace.path) ?? GitChurn()
            churnLabel.attributedStringValue = Self.churnText(churn)
        }
    }
}
