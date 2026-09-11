import AppKit

/// The CARRY control in the workspace form: a multi-select over what git ignores in the workspace
/// folder. Carry names what a worktree needs and git leaves out, so the candidates are already
/// known and nothing here is typed.
final class CarryPicker: NSView, ThemeReapplying {
    /// What git ignores in a workspace, given what it already copies. Blocking, so it runs
    /// off-main. Tests replace it.
    var probe: (URL, Set<String>) -> [String]? = WorktreeCarry.ignoredEntries

    /// The list or its selection changed: a catalog landed, or an entry was toggled.
    var onChanged: (() -> Void)?

    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?

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

    /// The stop the form arrows to, absent while the list has nothing to show.
    var focusStop: NSView? { dropdown }

    var isLoadingForTesting: Bool { isLoading }

    var statusForTesting: String? { status.isHidden ? nil : status.stringValue }
    var dropdownForTesting: CheckboxDropdown? { dropdown }

    private let slot = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private var dropdown: CheckboxDropdown?
    /// Bumped per reload so a superseded probe's answer is dropped rather than landing over a
    /// newer one. `DispatchWorkItem.cancel` cannot stop one that has already started.
    private var generation = 0
    /// Coalesces the reload, so walking a path costs a single `git status` rather than one per
    /// character typed.
    private var pending: DispatchWorkItem?
    private var isLoading = false
    var settle: TimeInterval = 0.35

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        status.font = .systemFont(ofSize: 11)
        status.textColor = Theme.current.chrome.ink(.muted)

        slot.orientation = .vertical
        slot.alignment = .leading
        slot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slot)
        NSLayoutConstraint.activate([
            slot.leadingAnchor.constraint(equalTo: leadingAnchor),
            slot.trailingAnchor.constraint(equalTo: trailingAnchor),
            slot.topAnchor.constraint(equalTo: topAnchor),
            slot.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        show(.message("Choose a folder first."))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Seed from the workspace being edited. No list yet: the catalog is whatever git says plus
    /// these, and building one from these alone would be torn down the moment the probe lands.
    func setCarried(_ entries: [String]) {
        carried = entries
        catalog = entries
    }

    func reapplyTheme() {
        status.textColor = Theme.current.chrome.ink(.muted)
        dropdown?.reapplyTheme()
    }

    // MARK: loading

    private func reload() {
        generation += 1
        let token = generation
        pending?.cancel()
        guard let folder = workspaceFolder else {
            catalog = carried
            render(unreadable: false)
            return
        }
        isLoading = true
        show(.message("Reading what git ignores…"))
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
    private func apply(_ ignored: [String]?) {
        guard let ignored else {
            catalog = carried
            render(unreadable: true)
            return
        }
        catalog = ignored + carried.filter { !ignored.contains($0) }
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
        // Every branch below swaps the control out, which takes an open list with it. Anything
        // arriving while one is up waits for it to close rather than shutting it under the user.
        if let dropdown, dropdown.isPopoverOpen {
            dropdown.onClosed = { [weak self] in self?.show(content) }
            return
        }
        for view in slot.arrangedSubviews { slot.removeArrangedSubview(view) }
        status.removeFromSuperview()
        dropdown?.removeFromSuperview()
        switch content {
        case .message(let text):
            dropdown = nil
            status.stringValue = text
            status.isHidden = false
            slot.addArrangedSubview(status)
        case .list:
            status.isHidden = true
            buildDropdown()
        }
    }

    /// Rebuilt rather than re-seeded: `CheckboxDropdown` fixes its row count at init, and the
    /// catalog's length is not known until git answers.
    private func buildDropdown() {
        let list = CheckboxDropdown(title: summary(), items: items()) { [weak self] index in
            self?.toggle(index)
        }
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
        onChanged?()
    }

    private func items() -> [CheckboxDropdownItem] {
        catalog.map { CheckboxDropdownItem(title: $0, isChecked: carried.contains($0)) }
    }

    private func summary() -> String {
        carried.isEmpty ? "Nothing chosen" : "\(carried.count) file\(carried.count == 1 ? "" : "s")"
    }
}
