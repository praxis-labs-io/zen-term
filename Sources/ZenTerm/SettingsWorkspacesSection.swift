import AppKit

final class SettingsWorkspacesSection: SettingsSection {
    var navTitle: String { "Workspaces" }
    var onExitToNav: (() -> Void)?
    var onEditWorkspace: ((Workspace?) -> Void)?
    /// Returns whether the write landed; on false the list is left as it was.
    var onReorder: ((_ moved: Workspace, _ with: Workspace) -> Bool)?

    private var rows: [WorkspaceRow] = []
    private let addButton = AppButton(title: "＋ Add workspace", variant: .muted)
    private weak var caption: NSTextField?
    private weak var emptyHint: NSTextField?
    private weak var reorderHint: NSTextField?
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
        caption?.textColor = Theme.current.chrome.ink(.muted)
        emptyHint?.textColor = Theme.current.chrome.ink(.muted)
        reorderHint?.textColor = Theme.current.chrome.ink(.faint)
        rows.forEach { $0.reapplyTheme() }
        addButton.reapplyTheme()
    }

    private func populateRows() {
        populate(with: nil)
        mountGeneration += 1
        let generation = mountGeneration
        ConfigLoader.loadWorkspaces { [weak self] workspaces in
            guard let self, generation == self.mountGeneration else { return }
            self.populate(with: workspaces)
        }
    }

    /// Restores focus after the rebuild, which otherwise leaves the card's keyboard dead.
    private func populate(with workspaces: [Workspace]?, focusing title: String? = nil) {
        guard let stack = rowsStack else { return }
        let focusedStop = stack.window?.firstResponder as? NSView
        let hadFocus = focusedStop.map { stop in detailStops().contains { $0 === stop } } ?? false
        let wasAddButton = focusedStop === addButton
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []

        let caption = SettingsDetail.groupCaption("Workspaces")
        self.caption = caption
        let reorderHintLabel = (workspaces?.count ?? 0) > 1 ? SettingsDetail.reorderHint() : nil
        reorderHint = reorderHintLabel
        let header = SettingsDetail.headerRow(caption: caption, hint: reorderHintLabel)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        if let workspaces, workspaces.isEmpty {
            let hint = NSTextField(
                labelWithString: "No workspaces yet. Add one to launch a folder with its own layout from ⌘P.")
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = Theme.current.chrome.ink(.muted)
            hint.lineBreakMode = .byWordWrapping
            hint.maximumNumberOfLines = 0
            emptyHint = hint
            stack.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else if let workspaces {
            for workspace in workspaces {
                let row = WorkspaceRow(workspace: workspace)
                row.onActivate = { [weak self, weak row] in row.map { self?.onEditWorkspace?($0.workspace) } }
                row.onArrowUp = { [weak self, weak row] in self?.moveFocus(from: row, delta: -1) }
                row.onArrowDown = { [weak self, weak row] in self?.moveFocus(from: row, delta: 1) }
                row.onMoveUp = { [weak self, weak row] in self?.move(row, delta: -1) }
                row.onMoveDown = { [weak self, weak row] in self?.move(row, delta: 1) }
                row.onTab = { [weak self, weak row] in self?.moveTab(from: row, delta: 1) }
                row.onBacktab = { [weak self, weak row] in self?.moveTab(from: row, delta: -1) }
                row.onExitToNav = { [weak self] in self?.onExitToNav?() }
                rows.append(row)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            GitRepoStatus.refresh(workspaces.map(\.path)) { [weak self] in
                self?.rows.forEach { $0.applyGitStatus() }
            }
        }
        stack.setCustomSpacing(10, after: header)

        let addRow = SettingsDetail.trailingRow(addButton)
        stack.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])

        if let title, let moved = rows.first(where: { $0.workspace.title == title }) {
            stack.window?.makeFirstResponder(moved)
            KeyboardFocus.reveal(moved, among: rows + [addButton])
            return
        }
        if hadFocus { stack.window?.makeFirstResponder(wasAddButton ? addButton : detailStops().first) }
    }

    /// Deferred a turn because the re-render frees this row while its `keyDown` is on the stack.
    private func move(_ row: WorkspaceRow?, delta: Int) {
        guard let row else { return }
        var list = rows.map(\.workspace)
        guard let from = list.firstIndex(where: { $0.title == row.workspace.title }) else { return }
        let to = from + delta
        guard list.indices.contains(to) else { return }
        let moved = list[from]
        let neighbour = list[to]
        list.swapAt(from, to)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.onReorder?(moved, neighbour) == true else { return }
            self.populate(with: list, focusing: moved.title)
        }
    }

    /// Bumped per mount, so a load from an earlier mount is dropped.
    private var mountGeneration = 0

    private func moveFocus(from view: NSView?, delta: Int) {
        guard let view else { return }
        let stops = rows + [addButton]
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta) { $0 }
    }

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

final class WorkspaceRow: NSView {
    let workspace: Workspace
    var onActivate: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onExitToNav: (() -> Void)?

    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
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
        subtitleLabel.textColor = Theme.current.chrome.ink(.muted)
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
        gitBadge.contentTintColor = Theme.current.chrome.ink(.faint)
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
        subtitleLabel.textColor = Theme.current.chrome.ink(.muted)
        gitBadge.contentTintColor = Theme.current.chrome.ink(.faint)
        restyle()
    }

    func applyGitStatus() {
        gitBadge.isHidden = GitRepoStatus.known(workspace.path) != true
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }
    override func drawFocusRingMask() {}

    /// `KeyboardFocus.key(for:)` decodes the keyCode alone, so ⌥ is checked here.
    override func keyDown(with event: NSEvent) {
        let key = KeyboardFocus.key(for: event)
        if KeyboardFocus.isOptionOnly(event) {
            switch key {
            case .up: onMoveUp?(); return
            case .down: onMoveDown?(); return
            default: break
            }
        }
        switch key {
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
        layer?.backgroundColor = isFocused ? chrome.fill(.active).cgColor : nil
        layer?.borderWidth = isFocused ? 1.5 : 0
        layer?.borderColor = isFocused ? chrome.accent.nsColor.cgColor : nil
    }
}
