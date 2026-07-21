import AppKit

/// The diff viewer: a chrome-native modal card over the active tile. The left column carries the
/// orientation cue and the three-scope selector above the file tree; the right column is the
/// side-by-side diff. Scopes (uncommitted / committed / all) are picked by an in-nav
/// `SegmentedControl`. A `ModalOverlay` sharing the card + backdrop + spring and Esc model with the
/// other overlays. Git work is injected as `loader` (a `nil` loader means the focused directory
/// isn't a repo), so the whole surface is drivable in a test without a real repo.
///
/// The `FileDiff` -> side-by-side rows step lives in `SideBySideDiff`; ZEN-228's unified layout swaps
/// that transform, not this shell.
final class DiffViewerOverlay: NSView, ModalOverlay {
    typealias LoadResult = Result<GitDiffRunner.DiffLoad, GitDiffRunner.Failure>
    /// Runs a scope's diff and calls back on the main thread. Injected so the overlay never touches
    /// `Process` itself; `WindowController` wires this to a `GitDiffRunner`.
    typealias Loader = (DiffScope, @escaping (LoadResult) -> Void) -> Void

    /// The scope order the segmented control shows, left to right. `All` (`.branch`) is the default
    /// and the union of the other two; both alternatives stay visible rather than hiding behind a menu.
    private static let scopeOrder: [DiffScope] = [.uncommitted, .committed, .branch]
    private static let scopeTitles = ["Uncommitted", "Committed", "All"]
    private static let defaultScopeIndex = 2

    private let loader: Loader?
    private let onCancel: () -> Void

    private let card = CardView()
    private var dismiss = DismissGate()

    // The persistent nav-column chrome (built once for a repo; the tree + diff swap beneath it).
    private let metaLabel = NSTextField(labelWithString: "")
    private var scopeSelector: SegmentedControl?
    private let navBorder = NSView()
    private let treeHost = NSView()
    private let diffHost = NSView()

    private var scope: DiffScope
    /// Guards against a slower older load overwriting a newer one when the scope is switched twice in
    /// quick succession: each `reload` stamps a token, and a completion whose token is stale is dropped.
    private var loadToken = 0

    /// Retained because `NSOutlineView` holds its data source and delegate weakly.
    private var outlineController: DiffTreeOutlineController?
    private var outlineView: NSOutlineView?
    private var diffTable: DiffPaneTable?
    private var selectedFilePath: String?

    init(background: NSColor, loader: Loader?, onCancel: @escaping () -> Void) {
        self.loader = loader
        self.onCancel = onCancel
        self.scope = Self.scopeOrder[Self.defaultScopeIndex]
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let backdrop = BackdropView(onClick: onCancel)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        CardChrome.apply(to: card, background: background)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            aspect(card.widthAnchor, to: widthAnchor, 0.85, priority: .defaultHigh),
            aspect(card.heightAnchor, to: heightAnchor, 0.85, priority: .defaultHigh),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.92),
            card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.92),
        ])

        if loader == nil {
            installMessageOnly()
        } else {
            installShell()
            reload(scope: scope)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func aspect(
        _ anchor: NSLayoutDimension, to other: NSLayoutDimension, _ multiplier: CGFloat,
        priority: NSLayoutConstraint.Priority
    ) -> NSLayoutConstraint {
        let constraint = anchor.constraint(equalTo: other, multiplier: multiplier)
        constraint.priority = priority
        return constraint
    }

    // MARK: ModalOverlay

    func focusInitialResponder() {
        window?.makeFirstResponder(outlineView ?? scopeSelector)
    }

    func animateIn() {
        superview?.layoutSubtreeIfNeeded()
        Motion.springScaleFade(card, appearing: true)
    }

    func animateOut(completion: @escaping () -> Void) {
        guard dismiss.begin() else { return }
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        dismiss.isDismissing ? nil : super.hitTest(point)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ModalEscape.handle(
            event, in: window, dismissing: dismiss.isDismissing, close: { self.onCancel() }
        ) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func reapplyTheme() {
        CardChrome.reapplyTheme(to: card)
        metaLabel.textColor = Theme.current.chrome.muted.nsColor
        navBorder.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        scopeSelector?.reapplyTheme()
        // Rebuild the swapped content from the retained state so tree + diff rows pick up the palette.
        render(currentState)
    }

    // MARK: shell

    /// The persistent split for a repo: nav column (meta + scope selector + border + tree) on the
    /// left, the diff pane on the right. Built once; loads only swap the tree and the diff.
    private func installShell() {
        metaLabel.font = .systemFont(ofSize: 11.5)
        metaLabel.textColor = Theme.current.chrome.muted.nsColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        let selector = SegmentedControl(
            options: Self.scopeTitles, selectedIndex: Self.defaultScopeIndex
        ) { [weak self] index in
            guard let self else { return }
            self.reload(scope: Self.scopeOrder[index])
        }
        selector.onArrowDown = { [weak self] in self?.focusTree() }
        selector.onTab = { [weak self] in self?.focusTree() }
        selector.onBacktab = { [weak self] in self?.focusDiff() }
        selector.translatesAutoresizingMaskIntoConstraints = false
        scopeSelector = selector

        navBorder.wantsLayer = true
        navBorder.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        navBorder.translatesAutoresizingMaskIntoConstraints = false

        treeHost.translatesAutoresizingMaskIntoConstraints = false

        let nav = NSView()
        nav.translatesAutoresizingMaskIntoConstraints = false
        nav.addSubview(metaLabel)
        nav.addSubview(selector)
        nav.addSubview(navBorder)
        nav.addSubview(treeHost)

        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false

        diffHost.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(nav)
        card.addSubview(rule)
        card.addSubview(diffHost)

        let inset: CGFloat = 12
        NSLayoutConstraint.activate([
            nav.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            nav.topAnchor.constraint(equalTo: card.topAnchor),
            nav.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            // The nav follows the card width but never squeezes the scope selector below its content.
            aspect(nav.widthAnchor, to: card.widthAnchor, 0.32, priority: .defaultHigh),
            nav.widthAnchor.constraint(greaterThanOrEqualTo: selector.widthAnchor, constant: inset * 2),

            metaLabel.leadingAnchor.constraint(equalTo: nav.leadingAnchor, constant: inset),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: nav.trailingAnchor, constant: -inset),
            metaLabel.topAnchor.constraint(equalTo: nav.topAnchor, constant: 14),

            selector.leadingAnchor.constraint(equalTo: nav.leadingAnchor, constant: inset),
            selector.trailingAnchor.constraint(lessThanOrEqualTo: nav.trailingAnchor, constant: -inset),
            selector.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 8),

            navBorder.leadingAnchor.constraint(equalTo: nav.leadingAnchor),
            navBorder.trailingAnchor.constraint(equalTo: nav.trailingAnchor),
            navBorder.topAnchor.constraint(equalTo: selector.bottomAnchor, constant: 12),
            navBorder.heightAnchor.constraint(equalToConstant: 1),

            treeHost.leadingAnchor.constraint(equalTo: nav.leadingAnchor),
            treeHost.trailingAnchor.constraint(equalTo: nav.trailingAnchor),
            treeHost.topAnchor.constraint(equalTo: navBorder.bottomAnchor),
            treeHost.bottomAnchor.constraint(equalTo: nav.bottomAnchor),

            rule.leadingAnchor.constraint(equalTo: nav.trailingAnchor),
            rule.topAnchor.constraint(equalTo: card.topAnchor),
            rule.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            rule.widthAnchor.constraint(equalToConstant: 1),

            diffHost.leadingAnchor.constraint(equalTo: rule.trailingAnchor),
            diffHost.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            diffHost.topAnchor.constraint(equalTo: card.topAnchor),
            diffHost.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }

    private func installMessageOnly() {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            host.topAnchor.constraint(equalTo: card.topAnchor),
            host.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        card.widthAnchor.constraint(equalToConstant: 420).isActive = true
        card.heightAnchor.constraint(equalToConstant: 220).isActive = true
        fill(host, with: message("This folder isn't a Git repository", muted: true))
    }

    // MARK: state + loading

    private enum State {
        case loading(DiffScope)
        case loaded(GitDiffRunner.DiffLoad)
        case empty(DiffScope)
        case failed(GitDiffRunner.Failure)
        case notARepo
    }
    private var currentState: State = .notARepo

    private func reload(scope: DiffScope) {
        self.scope = scope
        guard let loader else {
            render(.notARepo)
            return
        }
        loadToken += 1
        let token = loadToken
        render(.loading(scope))
        loader(scope) { [weak self] result in
            guard let self, token == self.loadToken else { return }
            switch result {
            case .success(let load):
                self.render(load.files.isEmpty ? .empty(scope) : .loaded(load))
            case .failure(let failure):
                self.render(.failed(failure))
            }
        }
    }

    private func render(_ state: State) {
        currentState = state
        if loader == nil {
            fill(reset(card), with: message("This folder isn't a Git repository", muted: true))
            return
        }
        outlineController = nil
        outlineView = nil
        diffTable = nil
        selectedFilePath = nil
        treeHost.subviews.forEach { $0.removeFromSuperview() }
        diffHost.subviews.forEach { $0.removeFromSuperview() }
        metaLabel.stringValue = orientationText(for: state)

        switch state {
        case .loaded(let load):
            installLoaded(files: load.files)
        case .loading:
            fill(diffHost, with: message("Loading…", muted: true))
        case .empty(let scope):
            fill(diffHost, with: message(emptyMessage(for: scope), muted: true))
        case .notARepo:
            fill(diffHost, with: message("This folder isn't a Git repository", muted: true))
        case .failed(let failure):
            fill(diffHost, with: message(failureMessage(for: failure), muted: false))
        }
    }

    private func installLoaded(files: [FileDiff]) {
        let controller = DiffTreeOutlineController(files: files) { [weak self] file in
            self?.selectFile(file)
        }
        outlineController = controller
        fill(treeHost, with: buildTreeScroll(controller: controller))

        let table = DiffPaneTable()
        table.translatesAutoresizingMaskIntoConstraints = false
        diffTable = table
        fill(diffHost, with: table)

        // Tab ring: scope selector -> tree -> diff pane -> back. Arrows scroll the pane once focused.
        if let outline = outlineView, let selector = scopeSelector {
            selector.nextKeyView = outline
            outline.nextKeyView = table.scrollFocusTarget
            table.scrollFocusTarget.nextKeyView = selector
            outline.expandItem(nil, expandChildren: true)
            if let first = controller.firstFile {
                let row = outline.row(forItem: first)
                if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
            }
        }
        if let first = controller.firstFile?.fileDiff {
            selectFile(first)
        }
    }

    private func buildTreeScroll(controller: DiffTreeOutlineController) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .small
        outline.indentationPerLevel = 12
        outline.backgroundColor = .clear
        outline.autoresizesOutlineColumn = true
        outline.dataSource = controller
        outline.delegate = controller
        outline.reloadData()
        outlineView = outline

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = SlimScroller()
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = outline
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private func selectFile(_ file: FileDiff) {
        selectedFilePath = file.path
        diffTable?.show(SideBySideDiff.rows(for: file))
    }

    private func focusTree() {
        guard let outlineView else { return }
        window?.makeFirstResponder(outlineView)
    }

    private func focusDiff() {
        guard let diffTable else { return }
        window?.makeFirstResponder(diffTable.scrollFocusTarget)
    }

    // MARK: orientation + messages

    private func orientationText(for state: State) -> String {
        switch state {
        case .loaded(let load):
            if let branch = load.baseBranch, let sha = load.baseSHA {
                return "comparing against \(branch) \(sha)"
            }
            return "comparing against HEAD"
        case .loading(let scope), .empty(let scope):
            return scope == .uncommitted ? "comparing against HEAD" : ""
        case .notARepo, .failed:
            return ""
        }
    }

    private func emptyMessage(for scope: DiffScope) -> String {
        switch scope {
        case .branch: return "No changes on this branch"
        case .committed: return "No committed changes on this branch"
        case .uncommitted: return "Nothing uncommitted"
        }
    }

    private func failureMessage(for failure: GitDiffRunner.Failure) -> String {
        switch failure {
        case .gitUnavailable: return "git isn't available"
        case .gitError(let message): return message.isEmpty ? "Couldn't read the diff" : message
        }
    }

    private func message(_ text: String, muted: Bool) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.font = .systemFont(ofSize: 13)
        label.textColor = muted ? Theme.current.chrome.muted.nsColor : Theme.current.chrome.foreground.nsColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])
        return container
    }

    @discardableResult
    private func reset(_ container: NSView) -> NSView {
        container.subviews.forEach { $0.removeFromSuperview() }
        return container
    }

    private func fill(_ container: NSView, with view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: test hooks

    /// The number of rows the file tree currently shows (expanded). Reads the real outline view so a
    /// test can't pass while the tree is empty or unmounted.
    var treeRowCountForTesting: Int { outlineView?.numberOfRows ?? 0 }
    /// The path of the file whose diff is in the right pane, or nil when no file is shown.
    var selectedFilePathForTesting: String? { selectedFilePath }
    /// The number of visual diff rows rendered in the right pane (hunk headers + line rows).
    var diffRowCountForTesting: Int { diffTable?.rowCountForTesting ?? 0 }
    /// Drive a tree selection the way a click/arrow would, so a test exercises the real selection path.
    func selectRowForTesting(_ row: Int) {
        outlineView?.selectRowIndexes([row], byExtendingSelection: false)
    }
    /// Drive the scope selector the way a click would (fires its `onChange`).
    func selectScopeForTesting(_ index: Int) {
        scopeSelector?.select(index)
    }
    var shownScopeForTesting: DiffScope { scope }
}
