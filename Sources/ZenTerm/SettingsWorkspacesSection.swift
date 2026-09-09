import AppKit

/// The Workspaces settings section: the configured workspaces, with add / edit / reorder, and each
/// repo's worktrees listed under it. Each workspace is a focusable `WorkspaceRow` — Return / click
/// opens the edit form (delete lives there), Up/Down move between rows, ⌥Up/⌥Down move the
/// workspace itself (the order the ⌘P picker and this list both read), Left exits to the nav, Esc
/// closes the card. A `WorktreeRow` under it removes that worktree. A trailing "Add workspace"
/// button opens a blank form. Add / edit route out through `onEditWorkspace`; the host presents
/// `AddWorkspaceOverlay`, which writes on submit / delete and hands back here, so the ⌘P picker
/// reflects the change with no restart. Mirrors `SettingsToolsSection`.
final class SettingsWorkspacesSection: SettingsSection {
    var navTitle: String { "Workspaces" }
    var onExitToNav: (() -> Void)?
    /// Set by the host: open the add / edit form. `nil` adds a new workspace; a value edits that one.
    var onEditWorkspace: ((Workspace?) -> Void)?
    /// Set by the host: remove this worktree of that workspace's repo, behind a confirm.
    var onRemoveWorktree: ((Worktree, Workspace) -> Void)?
    /// Set by the host. A worktree whose delete is already running offers no second Remove.
    var worktreeRemovals = WorktreeRemovalTracker()
    /// Set by the host: exchange these two workspaces' positions in the `workspaces` file. Returns
    /// whether the write landed — on false the list is left exactly as it was, so it can never show
    /// an order the file doesn't have.
    ///
    /// Two workspaces rather than a whole list (as Tools passes) because order here *is* file
    /// position: the write exchanges two `[Title]` blocks, and naming both is what lets it do that
    /// without assuming the rows are adjacent in the file.
    var onReorder: ((_ moved: Workspace, _ with: Workspace) -> Bool)?

    /// Workspace rows only, so ⌥↑/⌥↓ reorder the file and never move a worktree row.
    private var rows: [WorkspaceRow] = []
    /// Every focus stop in render order: a workspace, its worktrees, the next workspace, the button.
    private var stops: [NSView] = []
    /// Keyed by the workspace's standardized path, filled in when the background listing lands.
    private var listings: [URL: WorktreeListing] = [:]
    private let addButton = AppButton(title: "＋ Add workspace", variant: .muted)
    /// Rebuilt fresh by `populateRows` on each `makeDetailView` (the card rebuilds a section's detail
    /// on every switch), so their width constraints never accumulate on a retained view. Weak refs
    /// just let `reapplyTheme` recolor whichever pair is currently mounted.
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

    func detailStops() -> [NSView] { stops }

    func reapplyTheme() {
        caption?.textColor = Theme.current.chrome.ink(.muted)
        emptyHint?.textColor = Theme.current.chrome.ink(.muted)
        reorderHint?.textColor = Theme.current.chrome.ink(.faint)
        stops.forEach { ($0 as? ThemeReapplying)?.reapplyTheme() }
    }

    // MARK: rows

    /// Fill the rows stack from the live `workspaces` file. The list refreshes after an add / edit /
    /// delete because the form hands back to a freshly-built Settings → Workspaces (no in-place
    /// mutation here).
    private func populateRows() {
        // The file is read off the main thread, so the section mounts with its caption and
        // add button and the rows land a moment later. It must not render the "no workspaces yet"
        // hint in the meantime: that hint is the answer for an empty FILE, and flashing it while the
        // file is still being read tells the user their workspaces are gone.
        populate(with: nil)
        // The card rebuilds a section's detail on every switch, so a load from a previous mount can
        // still land here. Its answer belongs to a view that's gone; repopulating from it would
        // rebuild the current rows a second time under the user.
        mountGeneration += 1
        let generation = mountGeneration
        listings = [:]
        ConfigLoader.loadWorkspaces { [weak self] workspaces in
            guard let self, generation == self.mountGeneration else { return }
            self.populate(with: workspaces)
            // Two `git` calls per workspace, so the worktree rows land after the workspaces they
            // belong to, the way the ⌘P picker's do.
            GitRepoStatus.refreshWorktrees(workspaces.map(\.path)) { [weak self] path, listing in
                guard let self, generation == self.mountGeneration else { return }
                self.listings[path.standardizedFileURL] = listing
                self.populate(with: workspaces)
            }
        }
    }

    /// Render the section. `workspaces` is nil while the load is still out: caption and add button
    /// only, no rows and no empty-state hint. `focusing` is a workspace title to land focus on once
    /// the rows are up — how a reorder keeps the user on the row that just moved.
    private func populate(with workspaces: [Workspace]?, focusing title: String? = nil) {
        guard let stack = rowsStack else { return }
        // Rebuilding tears the current first responder out of the window, which resets focus to the
        // window itself and leaves the card's keyboard dead until a click. The user can already be
        // in here when the load lands (the add button is a stop from the first frame), so remember
        // whether focus was ours and put it back on the equivalent stop afterwards.
        let focusedStop = stack.window?.firstResponder as? NSView
        let hadFocus = focusedStop.map { stop in stops.contains { $0 === stop } } ?? false
        // Restored by identity rather than position: a worktree listing landing under the user
        // inserts rows above them, and restoring by index would move them to a different workspace.
        let heldStop = focusedStop.flatMap(Self.stopID)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []
        stops = []

        let caption = SettingsDetail.groupCaption("Workspaces")
        self.caption = caption
        // Nil while the load is still out, and for a one-workspace list: neither has anything to
        // reorder, so the hint would name a keystroke that does nothing.
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
            let configured = Set(workspaces.map { $0.path.standardizedFileURL })
            let owners = WorktreeGrouping.owners(among: workspaces, listings: listings)
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
                stops.append(row)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

                let children = WorktreeGrouping.worktrees(
                    of: workspace, listings: listings, owners: owners, configured: configured)
                for worktree in children {
                    let child = WorktreeRow(
                        worktree: worktree, parent: workspace,
                        isRemoving: worktreeRemovals.isRemoving(worktree.path))
                    child.onRemove = { [weak self] in self?.onRemoveWorktree?(worktree, workspace) }
                    child.onArrowUp = { [weak self, weak child] in self?.moveFocus(from: child, delta: -1) }
                    child.onArrowDown = { [weak self, weak child] in self?.moveFocus(from: child, delta: 1) }
                    child.onTab = { [weak self, weak child] in self?.moveTab(from: child, delta: 1) }
                    child.onBacktab = { [weak self, weak child] in self?.moveTab(from: child, delta: -1) }
                    child.onExitToNav = { [weak self] in self?.onExitToNav?() }
                    stops.append(child)
                    stack.addArrangedSubview(child)
                    child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
            }
            // The rows are up with whatever git status was already known; fill in the rest when the
            // background probe lands, the same way the ⌘P picker does.
            GitRepoStatus.refresh(workspaces.map(\.path)) { [weak self] in
                self?.rows.forEach { $0.applyGitStatus() }
            }
        }
        stack.setCustomSpacing(10, after: header)

        stops.append(addButton)
        let addRow = SettingsDetail.trailingRow(addButton)
        stack.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])

        // A reorder names the row it moved, so focus follows the workspace rather than the slot and
        // ⌥↓⌥↓ walks one down without re-finding it.
        if let title, let moved = rows.first(where: { $0.workspace.title == title }) {
            stack.window?.makeFirstResponder(moved)
            KeyboardFocus.reveal(moved, among: stops)
            return
        }
        // Focus was in this section before the rebuild, so put it back on the same stop, falling to
        // the first when that stop is gone, so arrows and Return keep working without a click.
        guard hadFocus else { return }
        let same = heldStop.flatMap { held in stops.first { Self.stopID($0) == held } }
        stack.window?.makeFirstResponder(same ?? stops.first)
    }

    /// What a focus stop is, across a rebuild. The add button is the stop a user lands on before
    /// any row has arrived, so it needs an identity of its own rather than falling to the first row.
    private static func stopID(_ view: NSView) -> AnyHashable? {
        if let row = view as? WorkspaceRow { return ["workspace", row.workspace.title] }
        if let row = view as? WorktreeRow { return ["worktree", row.worktree.path.path] }
        if view is AppButton { return ["add"] }
        return nil
    }

    /// Move a workspace one slot: exchange it with its neighbour in the file, then re-render in the
    /// new order with focus still on the row that moved.
    ///
    /// Renders from the array it just wrote rather than re-running `populateRows`, which would blank
    /// the list and wait on an off-main read — that flashes the rows away mid-⌥↓, and a second ⌥↓
    /// arriving before the read landed would pick its neighbour out of a stale list. A failed write
    /// returns false and nothing re-renders, so the list can't claim an order the file doesn't have.
    ///
    /// Deferred to the next runloop turn because the re-render *frees this row*: `populate` drops the
    /// last reference to it while its own `keyDown` is still on the stack.
    private func move(_ row: WorkspaceRow?, delta: Int) {
        guard let row else { return }
        var list = rows.map(\.workspace)
        guard let from = list.firstIndex(where: { $0.title == row.workspace.title }) else { return }
        let to = from + delta
        guard list.indices.contains(to) else { return }  // already at an end
        let moved = list[from]
        let neighbour = list[to]
        list.swapAt(from, to)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.onReorder?(moved, neighbour) == true else { return }
            self.populate(with: list, focusing: moved.title)
        }
    }

    /// Bumped per mount, so a load belonging to an earlier one is dropped rather than rendered.
    private var mountGeneration = 0

    private func moveFocus(from view: NSView?, delta: Int) {
        guard let view, let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta) { $0 }
    }

    /// Tab traversal, which differs from the arrows at the ends: Tab wraps from the last stop back
    /// to the first, and Shift-Tab retreats one stop, exiting to the nav only from the first —
    /// mirroring how Left exits.
    private func moveTab(from view: NSView?, delta: Int) {
        guard let view, let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        if delta < 0, anchor == 0 {
            onExitToNav?()
            return
        }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta, wrap: true) { $0 }
    }
}

/// One Workspaces row: a workspace's title and its folder path subtitle. The whole row is one focus
/// stop — Return / click opens the edit form (where delete lives), Up/Down (and Tab/Shift-Tab) move
/// rows, ⌥Up/⌥Down reorder the workspace itself, Left exits to nav. Mirrors `ToolFloatRow`
/// (workspaces have no shortcut, so no keycap).
final class WorkspaceRow: NSView, ThemeReapplying {
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
    /// A muted Git logo, trailing, when the folder is a repo — mirrors the ⌘P picker's badge, and
    /// like the picker's it starts hidden and turns on from `GitRepoStatus` once a background probe
    /// lands (the check is filesystem I/O, which never runs on the main thread).
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
        let key = KeyboardFocus.key(for: event)
        // ⌥Up/⌥Down reorder the workspace instead of moving focus. `KeyboardFocus.key(for:)` decodes
        // the keyCode alone, so ⌥↑ arrives indistinguishable from a plain `.up` — the modifier check
        // has to happen here.
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

/// One worktree row, indented under the workspace whose repo it belongs to: its branch and its
/// folder, with a Remove button. The row is one focus stop and ⌫ on it removes, so a click can only
/// focus: a whole row that deletes on click is one slip from a folder that is gone. Return does
/// nothing, because Return opens things everywhere else in Settings.
final class WorktreeRow: NSView, ThemeReapplying {
    /// How far the row sits inside its workspace, mirroring the ⌘P picker's child indent.
    static let childIndent: CGFloat = 16

    let worktree: Worktree
    let parent: Workspace
    var onRemove: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onExitToNav: (() -> Void)?

    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    /// Absent on a locked worktree and disabled while a delete is running: `WorktreeStore.remove`
    /// obeys a lock, so offering a button that always fails is worse than offering none.
    private let removeButton: AppButton?
    /// Says why there is no button, so a locked worktree does not read as an oversight.
    private let lockedLabel: NSTextField?
    private var isFocused = false { didSet { restyle() } }

    init(worktree: Worktree, parent: Workspace, isRemoving: Bool) {
        self.worktree = worktree
        self.parent = parent
        // A detached worktree's folder name is whatever directory it was made in, which reads like
        // a branch and is not one, so the short head stands in.
        titleLabel = NSTextField(labelWithString: worktree.branch ?? String(worktree.head.prefix(7)))
        subtitleLabel = NSTextField(
            labelWithString: PathDisplay.abbreviatingHome(worktree.path.path))
        removeButton = worktree.isLocked ? nil : AppButton(title: "Remove", variant: .destructive)
        lockedLabel = worktree.isLocked ? NSTextField(labelWithString: "Locked") : nil

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        titleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        lockedLabel?.font = .systemFont(ofSize: 11)
        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        removeButton?.isEnabled = !isRemoving
        removeButton?.setContentHuggingPriority(.required, for: .horizontal)
        removeButton?.onTap = { [weak self] in self?.requestRemove() }
        let trailing: NSView? = removeButton ?? lockedLabel
        let controls = NSStackView(views: [labels, spacer] + (trailing.map { [$0] } ?? []))
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6 + Self.childIndent),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        applyInk()
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        applyInk()
        removeButton?.reapplyTheme()
        restyle()
    }

    /// The row is a child, so it sits a weight quieter than the workspace above it.
    private func applyInk() {
        let chrome = Theme.current.chrome
        titleLabel.textColor = chrome.ink(.subtle)
        subtitleLabel.textColor = chrome.ink(.muted)
        lockedLabel?.textColor = chrome.ink(.faint)
    }

    /// No-op while the delete is already running, so ⌫ cannot start a second one behind the button
    /// that has already been disabled for it.
    private func requestRemove() {
        guard removeButton?.isEnabled == true else { return }
        onRemove?()
    }

    // MARK: focus + keyboard

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }
    override func drawFocusRingMask() {}

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .left: onExitToNav?()
        case .delete: requestRemove()
        case .tab(let shift) where onTab != nil || onBacktab != nil:
            shift ? onBacktab?() : onTab?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func restyle() {
        let chrome = Theme.current.chrome
        layer?.backgroundColor = isFocused ? chrome.fill(.active).cgColor : nil
        layer?.borderWidth = isFocused ? 1.5 : 0
        layer?.borderColor = isFocused ? chrome.accent.nsColor.cgColor : nil
    }
}
