import AppKit

/// The CARRY control in the workspace form: a multi-select over what git ignores in the workspace
/// folder. Carry names what a worktree needs and git leaves out, so the candidates are already
/// known and nothing here is typed.
final class CarryPicker: NSView, ThemeReapplying {
    /// What git ignores in a workspace, given what it already copies. Blocking, so it runs
    /// off-main. Tests replace it.
    var probe: (URL, Set<String>) -> IgnoredCatalog? = WorktreeCarry.ignoredEntries

    /// The list or its selection changed: a catalog landed, or an entry was toggled.
    var onChanged: (() -> Void)?

    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    /// The control stopped being a focus stop while it held the ring. The form moves on rather
    /// than leaving the next arrow press with nowhere to go.
    var onFocusLost: (() -> Void)?

    /// The folder the catalog is read from. Setting it reloads.
    var workspaceFolder: URL? {
        didSet {
            guard workspaceFolder != oldValue else { return }
            reload()
        }
    }

    /// Checked, in catalog order.
    private(set) var carried: [String] = []

    /// What the list offers: what git ignores today, plus anything already carried that git no
    /// longer ignores, so a hand-authored entry survives a save instead of vanishing from the file.
    private(set) var catalog: [String] = []
    /// The rows shown while nothing is typed. A folded folder stands in for its files here; the
    /// files stay in `catalog`, reachable by typing their name.
    private(set) var resting: [String] = []
    private var fileCounts: [String: Int] = [:]
    private var directories: Set<String> = []

    /// The stop the form arrows to. The placeholder is one while git is being asked, so the ring
    /// does not gain a stop under the user the moment the catalog lands; the settled states with
    /// nothing to pick are skipped.
    var focusStop: NSView? { dropdown ?? (isLoading ? status : nil) }

    var isLoadingForTesting: Bool { isLoading }

    var statusForTesting: String? { status.isHidden ? nil : status.title }
    var isSpinningForTesting: Bool { status.isSpinning }
    var summaryForTesting: String { summary() }
    var detailForTesting: String { detail.stringValue }
    var dropdownForTesting: CheckboxDropdown? { dropdown }

    private let slot = NSStackView()
    private let detail = NSTextField(labelWithString: "")
    private let status = PlaceholderSelect()
    private var dropdown: CheckboxDropdown?
    /// Bumped per reload so a superseded probe's answer is dropped rather than landing over a
    /// newer one. `DispatchWorkItem.cancel` cannot stop one that has already started.
    private var generation = 0
    /// Coalesces the reload, so walking a path costs a single `git status` rather than one per
    /// character typed.
    private var pending: DispatchWorkItem?
    private var isLoading = false
    private var deferredWork: (() -> Void)?
    var settle: TimeInterval = 0.35

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        slot.orientation = .vertical
        slot.alignment = .leading
        slot.translatesAutoresizingMaskIntoConstraints = false

        status.onArrowUp = { [weak self] in self?.onArrowUp?() }
        status.onArrowDown = { [weak self] in self?.onArrowDown?() }
        status.onTab = { [weak self] in self?.onTab?() }
        status.onBacktab = { [weak self] in self?.onBacktab?() }

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = Theme.current.chrome.ink(.muted)
        detail.maximumNumberOfLines = 0
        detail.lineBreakMode = .byWordWrapping
        detail.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [slot, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            slot.widthAnchor.constraint(equalTo: column.widthAnchor),
            detail.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        renderDetail()
        show(.message("Choose a folder first."))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Seed from the workspace being edited. No list yet: the catalog is whatever git says plus
    /// these, and building one from these alone would be torn down the moment the probe lands.
    func setCarried(_ entries: [String]) {
        carried = entries
        catalog = catalog.isEmpty ? entries : catalog
        resting = resting.isEmpty ? entries : resting
        dropdown?.setItems(items(), title: summary())
        renderDetail()
    }

    func reapplyTheme() {
        status.reapplyTheme()
        detail.textColor = Theme.current.chrome.ink(.muted)
        dropdown?.reapplyTheme()
    }

    // MARK: loading

    private func reload() {
        generation += 1
        let token = generation
        pending?.cancel()
        guard let folder = workspaceFolder else {
            // The whole catalog, not just `catalog`: a stale `resting` claims git ignores nothing
            // here, and a stale count renders `170 files` against an unrelated row.
            isLoading = false
            catalog = carried
            resting = carried
            fileCounts = [:]
            directories = []
            whenListIdle { self.show(.message("Choose a folder first.")) }
            onChanged?()
            return
        }
        isLoading = true
        whenListIdle { self.show(.message("Reading what git ignores…")) }
        let probe = probe
        let chosen = Set(carried)
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                let ignored = probe(folder, chosen)
                DispatchQueue.main.async {
                    guard let self, token == self.generation else { return }
                    self.apply(ignored)
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
    }

    /// How long the folder field is given to stop changing before git is asked. It changes per
    /// keystroke, and a typed path passes through real directories on the way.

    /// Nil is not "nothing ignored": the folder is not a repo, or git could not be asked, and the
    /// message says so rather than showing an empty list that reads as a repo with nothing to carry.
    /// Run `work` once no list is open. Everything that reshapes this control goes through here:
    /// swapping `catalog` under an open list leaves the rows the user can see indexing entries they
    /// cannot, so a click carries whatever now sits at that row's position.
    private func whenListIdle(_ work: @escaping () -> Void) {
        guard let dropdown, dropdown.isPopoverOpen else { return work() }
        deferredWork = work
        dropdown.onClosed = { [weak self] in
            guard let self, let work = self.deferredWork else { return }
            self.deferredWork = nil
            work()
        }
    }

    private func apply(_ ignored: IgnoredCatalog?) {
        whenListIdle { self.applyNow(ignored) }
    }

    private func applyNow(_ ignored: IgnoredCatalog?) {
        guard let ignored else {
            catalog = carried
            resting = carried
            fileCounts = [:]
            directories = []
            render(unreadable: true)
            return
        }
        let extras = carried.filter { !ignored.entries.contains($0) }
        catalog = ignored.entries + extras
        resting = ignored.resting + extras
        fileCounts = ignored.fileCounts
        directories = ignored.directories
        render(unreadable: false)
    }

    private func render(unreadable: Bool) {
        isLoading = false
        renderContent(unreadable: unreadable)
        onChanged?()
    }

    private func renderContent(unreadable: Bool) {
        guard !catalog.isEmpty else {
            show(.message(unreadable ? "This folder isn't a git repo." : "Git ignores nothing here yet."))
            return
        }
        show(.list)
    }

    // MARK: the list

    private enum Content {
        case message(String)
        case list
    }

    private func show(_ content: Content) {
        // Read before the teardown below: a view out of the tree has no window to be focused in.
        let placeholderHadFocus = KeyboardFocus.isFocused(status, in: window)
        for view in slot.arrangedSubviews { slot.removeArrangedSubview(view) }
        status.removeFromSuperview()
        dropdown?.removeFromSuperview()
        switch content {
        case .message(let text):
            let listHadFocus = dropdown.map { KeyboardFocus.isFocused($0, in: window) } ?? false
            dropdown = nil
            status.isFocusable = isLoading
            status.set(title: text, isLoading: isLoading)
            status.isHidden = false
            slot.addArrangedSubview(status)
            status.widthAnchor.constraint(equalTo: slot.widthAnchor).isActive = true
            // Both directions, or the ring lands nowhere: loading to a settled message leaves the
            // placeholder unfocusable, and a list replaced by one takes the focus out with it.
            guard placeholderHadFocus || listHadFocus else { return }
            if status.isFocusable {
                window?.makeFirstResponder(status)
            } else {
                onFocusLost?()
            }
        case .list:
            // Hand focus on rather than dropping it: the placeholder holding it is about to leave
            // the view tree, and a form whose ring lands nowhere eats the next arrow press.
            status.isHidden = true
            status.isFocusable = false
            buildDropdown()
            if placeholderHadFocus, let dropdown { window?.makeFirstResponder(dropdown) }
        }
    }

    /// Rebuilt rather than re-seeded: `CheckboxDropdown` fixes its row count at init, and the
    /// catalog's length is not known until git answers.
    private func buildDropdown() {
        let list = CheckboxDropdown(title: summary(), items: items()) { [weak self] index in
            self?.toggle(index)
        }
        list.restingIndices = restingIndices()
        list.onArrowUp = { [weak self] in self?.onArrowUp?() }
        list.onArrowDown = { [weak self] in self?.onArrowDown?() }
        list.onTab = { [weak self] in self?.onTab?() }
        list.onBacktab = { [weak self] in self?.onBacktab?() }
        dropdown = list
        slot.addArrangedSubview(list)
        list.widthAnchor.constraint(equalTo: slot.widthAnchor).isActive = true
    }

    private func toggle(_ index: Int) {
        guard catalog.indices.contains(index) else { return }
        let entry = catalog[index]
        if carried.contains(entry) {
            carried.removeAll { $0 == entry }
        } else {
            carried = catalog.filter { carried.contains($0) || $0 == entry }
        }
        dropdown?.setItems(items(), title: summary())
        dropdown?.restingIndices = restingIndices()
        renderDetail()
        onChanged?()
    }

    private func items() -> [CheckboxDropdownItem] {
        catalog.map { entry in
            CheckboxDropdownItem(
                title: entry, isChecked: carried.contains(entry),
                note: fileCounts[entry].map { "\($0) files" },
                symbol: directories.contains(entry) ? "folder" : "doc")
        }
    }

    /// A checked row is shown at rest wherever it sits, so a file picked out of a folded folder
    /// does not disappear behind that folder the moment the list reopens.
    private func restingIndices() -> [Int] {
        let shown = Set(resting).union(carried)
        return catalog.indices.filter { shown.contains(catalog[$0]) }
    }

    /// The control's shape while there is no list: a select-sized box holding the reason, and a
    /// spinner while git is being asked. A bare line of text read as the control having failed to
    /// render rather than as a state it was in.
    private final class PlaceholderSelect: NSView {
        private let label = NSTextField(labelWithString: "")
        private let spinner = Spinner()

        var title: String { label.stringValue }
        var isSpinning: Bool { spinner.isSpinning }

        /// A stop only while there is a reason to stand here. Set by the owner per state.
        var isFocusable = false {
            didSet {
                guard !isFocusable, isFocused else { return }
                window?.makeFirstResponder(nil)
            }
        }
        var onArrowUp: (() -> Void)?
        var onArrowDown: (() -> Void)?
        var onTab: (() -> Void)?
        var onBacktab: (() -> Void)?

        private var isFocused = false

        override var acceptsFirstResponder: Bool { isFocusable }

        override func becomeFirstResponder() -> Bool {
            isFocused = true
            restyle()
            return true
        }

        override func resignFirstResponder() -> Bool {
            isFocused = false
            restyle()
            return super.resignFirstResponder()
        }

        override func drawFocusRingMask() {}

        /// Consumes everything else, the way the open list does: there is nothing here to activate,
        /// and letting a key fall through would run it against whatever is behind the card.
        override func keyDown(with event: NSEvent) {
            switch KeyboardFocus.key(for: event) {
            case .up: onArrowUp?()
            case .down: onArrowDown?()
            case .tab(let shift): shift ? onBacktab?() : onTab?()
            case .escape: super.keyDown(with: event)
            default: break
            }
        }

        init() {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            layer?.cornerRadius = 6
            PopoverButtonStyle.applyRestFill(to: self)
            layer?.borderWidth = 1

            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            addSubview(spinner)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 30),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                spinner.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
                spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
                spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            applyColors()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func set(title: String, isLoading: Bool) {
            label.stringValue = title
            spinner.isHidden = !isLoading
            spinner.isSpinning = isLoading
        }

        func reapplyTheme() {
            PopoverButtonStyle.applyRestFill(to: self)
            applyColors()
            spinner.reapplyTheme()
        }

        private func restyle() {
            PopoverButtonStyle.apply(to: self, isFocused: isFocused, isOpen: false)
            label.textColor = Theme.current.chrome.ink(.muted)
        }

        private func applyColors() {
            label.textColor = Theme.current.chrome.ink(.muted)
            layer?.borderColor = Theme.current.chrome.fill(alpha: ChromeTheme.border).cgColor
        }
    }

    private func summary() -> String {
        carried.isEmpty ? "Nothing chosen" : "\(carried.count) file\(carried.count == 1 ? "" : "s")"
    }

    /// The line under the select: what the control is for until something is chosen, then what is
    /// chosen. A count alone meant opening the list and scrolling all of it to see the selection,
    /// and these are full paths, which no button-width summary can hold.
    static let captionText = "Files git ignores that a worktree needs to run."

    private func renderDetail() {
        detail.stringValue = carried.isEmpty ? Self.captionText : carried.joined(separator: "\n")
    }
}
