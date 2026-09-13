import AppKit

final class CarryPicker: NSView, ThemeReapplying {
    var probe: (URL, Set<String>) -> IgnoredCatalog? = WorktreeCarry.ignoredEntries

    var onChanged: (() -> Void)?

    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onFocusLost: (() -> Void)?

    var workspaceFolder: URL? {
        didSet {
            guard workspaceFolder != oldValue else { return }
            reload()
        }
    }

    private(set) var carried: [String] = []

    /// Keeps carried entries git no longer ignores, so a hand-authored entry survives a save.
    private(set) var catalog: [String] = []
    private(set) var resting: [String] = []
    private var fileCounts: [String: Int] = [:]
    private var directories: Set<String> = []

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
    /// `DispatchWorkItem.cancel` cannot stop a probe that has already started.
    private var generation = 0
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

    private func reload() {
        generation += 1
        let token = generation
        pending?.cancel()
        guard let folder = workspaceFolder else {
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

    /// Swapping `catalog` under an open list would make a click carry whatever now sits at that row.
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

    private enum Content {
        case message(String)
        case list
    }

    private func show(_ content: Content) {
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
            guard placeholderHadFocus || listHadFocus else { return }
            if status.isFocusable {
                window?.makeFirstResponder(status)
            } else {
                onFocusLost?()
            }
        case .list:
            status.isHidden = true
            status.isFocusable = false
            buildDropdown()
            if placeholderHadFocus, let dropdown { window?.makeFirstResponder(dropdown) }
        }
    }

    /// Rebuilt rather than re-seeded: `CheckboxDropdown` fixes its row count at init.
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

    private func restingIndices() -> [Int] {
        let shown = Set(resting).union(carried)
        return catalog.indices.filter { shown.contains(catalog[$0]) }
    }

    private final class PlaceholderSelect: NSView {
        private let label = NSTextField(labelWithString: "")
        private let spinner = Spinner()

        var title: String { label.stringValue }
        var isSpinning: Bool { spinner.isSpinning }

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

    static let captionText = "Files git ignores that a worktree needs to run."

    private func renderDetail() {
        detail.stringValue = carried.isEmpty ? Self.captionText : carried.joined(separator: "\n")
    }
}
