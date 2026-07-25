import AppKit

/// The Workspaces settings section: the configured workspaces, with add / edit. Each workspace is a
/// focusable `WorkspaceRow` — Return / click opens the edit form (delete lives there), Up/Down move
/// between rows, Left exits to the nav, Esc closes the card. A trailing "Add workspace" button opens
/// a blank form. Add / edit route out through `onEditWorkspace`; the host presents
/// `AddWorkspaceOverlay`, which writes on submit / delete and hands back here, so the ⌘⇧P picker
/// reflects the change with no restart. Mirrors `SettingsToolsSection`.
final class SettingsWorkspacesSection: SettingsSection {
    var navTitle: String { "Workspaces" }
    var onExitToNav: (() -> Void)?
    /// Set by the host: open the add / edit form. `nil` adds a new workspace; a value edits that one.
    var onEditWorkspace: ((Workspace?) -> Void)?

    private var rows: [WorkspaceRow] = []
    private let addButton = AppButton(title: "＋ Add workspace", variant: .muted)
    /// Rebuilt fresh by `populateRows` on each `makeDetailView` (the card rebuilds a section's detail
    /// on every switch), so their width constraints never accumulate on a retained view. Weak refs
    /// just let `reapplyTheme` recolor whichever pair is currently mounted.
    private weak var caption: NSTextField?
    private weak var emptyHint: NSTextField?
    private var rowsStack: NSStackView?

    func makeDetailView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack = stack

        addButton.isKeyboardFocusable = true
        addButton.onArrowUp = { [weak self] in self?.moveFocus(from: self?.addButton, delta: -1) }
        addButton.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        addButton.onTab = { [weak self] in self?.moveTab(from: self?.addButton, delta: 1) }
        addButton.onBacktab = { [weak self] in self?.moveTab(from: self?.addButton, delta: -1) }
        addButton.onTap = { [weak self] in self?.onEditWorkspace?(nil) }

        populateRows()
        return SettingsDetail.scroll(for: stack)
    }

    func detailStops() -> [NSView] { rows + [addButton] }

    func reapplyTheme() {
        caption?.textColor = Theme.current.chrome.ink(alpha: 0.4)
        emptyHint?.textColor = Theme.current.chrome.ink(alpha: 0.5)
        rows.forEach { $0.reapplyTheme() }
        addButton.reapplyTheme()
    }

    // MARK: rows

    /// Fill the rows stack from the live `workspaces` file. The list refreshes after an add / edit /
    /// delete because the form hands back to a freshly-built Settings → Workspaces (no in-place
    /// mutation here).
    private func populateRows() {
        guard let stack = rowsStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []

        let caption = SettingsDetail.groupCaption("Workspaces")
        self.caption = caption
        stack.addArrangedSubview(caption)
        caption.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let workspaces = ConfigLoader.loadWorkspaces()
        if workspaces.isEmpty {
            let hint = NSTextField(
                labelWithString: "No workspaces yet. Add one to launch a folder with its own layout from ⌘⇧P.")
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = Theme.current.chrome.ink(alpha: 0.5)
            hint.lineBreakMode = .byWordWrapping
            hint.maximumNumberOfLines = 0
            emptyHint = hint
            stack.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else {
            for workspace in workspaces {
                let row = WorkspaceRow(workspace: workspace)
                row.onActivate = { [weak self, weak row] in row.map { self?.onEditWorkspace?($0.workspace) } }
                row.onArrowUp = { [weak self, weak row] in self?.moveFocus(from: row, delta: -1) }
                row.onArrowDown = { [weak self, weak row] in self?.moveFocus(from: row, delta: 1) }
                row.onTab = { [weak self, weak row] in self?.moveTab(from: row, delta: 1) }
                row.onBacktab = { [weak self, weak row] in self?.moveTab(from: row, delta: -1) }
                row.onExitToNav = { [weak self] in self?.onExitToNav?() }
                rows.append(row)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            // The rows are up with whatever git status was already known; fill in the rest when the
            // background probe lands, the same way the ⌘⇧P picker does.
            GitRepoStatus.refresh(workspaces.map(\.path)) { [weak self] in
                self?.rows.forEach { $0.applyGitStatus() }
            }
        }
        stack.setCustomSpacing(10, after: caption)

        let addRow = SettingsDetail.trailingRow(addButton)
        stack.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
    }

    private func moveFocus(from view: NSView?, delta: Int) {
        guard let view else { return }
        let stops = rows + [addButton]
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta) { $0 }
    }

    /// Tab traversal, which differs from the arrows at the ends: Tab wraps from the last stop back
    /// to the first, and Shift-Tab retreats one stop, exiting to the nav only from the first —
    /// mirroring how Left exits.
    private func moveTab(from view: NSView?, delta: Int) {
        guard let view else { return }
        let stops = rows + [addButton]
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        if delta < 0, anchor == 0 {
            onExitToNav?()
            return
        }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta, wrap: true) { $0 }
    }
}

/// One Workspaces row: a workspace's title and its folder path subtitle. The whole row is one focus
/// stop — Return / click opens the edit form (where delete lives), Up/Down (and Tab/Shift-Tab) move
/// rows, Left exits to nav. Mirrors `ToolFloatRow` (workspaces have no shortcut, so no keycap).
final class WorkspaceRow: NSView {
    let workspace: Workspace
    var onActivate: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onExitToNav: (() -> Void)?

    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    /// A muted Git logo, trailing, when the folder is a repo — mirrors the ⌘⇧P picker's badge, and
    /// like the picker's it starts hidden and turns on from `GitRepoStatus` once a background probe
    /// lands (the check is filesystem I/O, which never runs on the main thread — ZEN-90).
    private let gitBadge = NSImageView()
    private var isFocused = false { didSet { restyle() } }

    init(workspace: Workspace) {
        self.workspace = workspace
        titleLabel = NSTextField(labelWithString: workspace.title)
        subtitleLabel = NSTextField(labelWithString: PathDisplay.abbreviatingHome(workspace.path.path))

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = Theme.current.chrome.ink(alpha: 0.5)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        gitBadge.image = IconCatalog.gitBadge()
        gitBadge.setAccessibilityLabel("Git repository")
        gitBadge.contentTintColor = Theme.current.chrome.ink(alpha: 0.35)
        gitBadge.setContentHuggingPriority(.required, for: .horizontal)
        applyGitStatus()
        let controls = NSStackView(views: [labels, spacer, gitBadge])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        subtitleLabel.textColor = Theme.current.chrome.ink(alpha: 0.5)
        gitBadge.contentTintColor = Theme.current.chrome.ink(alpha: 0.35)
        restyle()
    }

    /// Show the badge when this workspace's folder is a known repo. Run at build time and again
    /// whenever a `GitRepoStatus.refresh` lands.
    func applyGitStatus() {
        gitBadge.isHidden = GitRepoStatus.known(workspace.path) != true
    }

    // MARK: focus + keyboard

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }
    override func drawFocusRingMask() {}

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .activate: onActivate?()
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .left: onExitToNav?()
        case .tab(let shift) where onTab != nil || onBacktab != nil:
            shift ? onBacktab?() : onTab?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onActivate?()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func restyle() {
        let chrome = Theme.current.chrome
        layer?.backgroundColor = isFocused ? chrome.ink(alpha: 0.10).cgColor : nil
        layer?.borderWidth = isFocused ? 1.5 : 0
        layer?.borderColor = isFocused ? chrome.accent.nsColor.cgColor : nil
    }
}
