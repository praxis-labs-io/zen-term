import AppKit

// Chips are framed by hand so a dragged chip can leave its slot while the others close the gap.
final class WorkspaceTabStrip: NSView {
    private static let chipSpacing: CGFloat = 4
    private static let addSize: CGFloat = 26
    private static let hintSpacing: CGFloat = 10

    var onSelect: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    var onRemove: ((Int) -> Void)?
    var onRename: ((Int, String) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?

    private(set) var chips: [WorkspaceTabChip] = []
    private var selected = 0
    private var drag: (index: Int, offset: CGFloat)?
    private lazy var addButton = IconButton(
        symbol: "plus", size: NSSize(width: Self.addSize, height: Self.addSize), pointSize: 12,
        accessibilityLabel: "Add tab", shortcut: { CommandCatalog.spec(for: .newTab).shortcut }
    ) { [weak self] in self?.onAdd?() }
    private let renameHint = NSStackView()
    private var hintLabels: [NSTextField] = []
    private var hintCaps: [KeycapView] = []

    var addButtonForTesting: IconButton { addButton }
    var isRenameHintVisibleForTesting: Bool { !renameHint.isHidden }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addButton.translatesAutoresizingMaskIntoConstraints = true
        addSubview(addButton)
        buildRenameHint()
        heightAnchor.constraint(equalToConstant: WorkspaceTabChip.height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var selectedChip: WorkspaceTabChip? { chips.indices.contains(selected) ? chips[selected] : nil }

    var isRenaming: Bool { chips.contains(where: \.isRenaming) }

    func render(_ form: WorkspaceForm) {
        while chips.count < form.tabs.count { chips.append(makeChip()) }
        while chips.count > form.tabs.count { chips.removeLast().removeFromSuperview() }
        selected = form.selected
        for (index, chip) in chips.enumerated() {
            let fallback = form.tabs[index].main ?? WorkspaceForm.shellLabel
            chip.update(
                title: form.chipLabel(at: index), defaultName: fallback, selected: index == form.selected,
                opensFocused: form.launchFocus.tab == index, removable: !form.isSoleTab)
        }
        needsLayout = true
    }

    func focusSelectedChip() {
        guard let chip = selectedChip else { return }
        window?.makeFirstResponder(chip)
    }

    func beginRenamingSelected() { selectedChip?.beginRename() }

    @discardableResult
    func cancelRename() -> Bool { chips.contains { $0.cancelRename() } }

    func reapplyTheme() {
        chips.forEach { $0.reapplyTheme() }
        addButton.reapplyTheme()
        hintCaps.forEach { $0.reapplyTheme() }
        hintLabels.forEach { $0.textColor = Theme.current.chrome.ink(.muted) }
    }

    override func layout() {
        super.layout()
        let widths = chips.map(\.fittingWidth)
        let home = slotOrigins(widths)
        var x: CGFloat = 0
        for index in displayOrder() {
            let originX = drag.map { $0.index == index ? home[index] + $0.offset : x } ?? x
            chips[index].frame = CGRect(x: originX, y: 0, width: widths[index], height: WorkspaceTabChip.height)
            x += widths[index] + Self.chipSpacing
        }
        addButton.frame = CGRect(x: x, y: 0, width: Self.addSize, height: Self.addSize)
        renameHint.isHidden = !isRenaming
        let hintSize = renameHint.fittingSize
        renameHint.frame = CGRect(
            x: x + Self.addSize + Self.hintSpacing, y: (WorkspaceTabChip.height - hintSize.height) / 2,
            width: hintSize.width, height: hintSize.height)
    }

    private func slotOrigins(_ widths: [CGFloat]) -> [CGFloat] {
        var origins: [CGFloat] = []
        var x: CGFloat = 0
        for width in widths {
            origins.append(x)
            x += width + Self.chipSpacing
        }
        return origins
    }

    private func displayOrder() -> [Int] {
        var order = Array(chips.indices)
        guard let drag else { return order }
        let target = dropIndex(for: drag)
        order.remove(at: drag.index)
        order.insert(drag.index, at: target)
        return order
    }

    private func dropIndex(for drag: (index: Int, offset: CGFloat)) -> Int {
        let widths = chips.map(\.fittingWidth)
        let origins = slotOrigins(widths)
        let center = origins[drag.index] + drag.offset + widths[drag.index] / 2
        var target = 0
        for index in chips.indices where index != drag.index {
            if center > origins[index] + widths[index] / 2 { target += 1 }
        }
        return target
    }

    private func makeChip() -> WorkspaceTabChip {
        let chip = WorkspaceTabChip()
        addSubview(chip)
        chip.onSelect = { [weak self, weak chip] in
            guard let self, let chip, let index = self.chips.firstIndex(where: { $0 === chip }) else { return }
            self.onSelect?(index)
        }
        chip.onRemove = { [weak self, weak chip] in self?.withIndex(of: chip) { self?.onRemove?($0) } }
        chip.onRename = { [weak self, weak chip] name in self?.withIndex(of: chip) { self?.onRename?($0, name) } }
        chip.onRenamingChanged = { [weak self] in
            guard let self else { return }
            self.renameHint.isHidden = !self.isRenaming
            self.needsLayout = true
        }
        chip.onArrowLeft = { [weak self, weak chip] in self?.withIndex(of: chip) { self?.step(from: $0, by: -1) } }
        chip.onArrowRight = { [weak self, weak chip] in self?.withIndex(of: chip) { self?.step(from: $0, by: 1) } }
        chip.onArrowUp = { [weak self] in self?.onArrowUp?() }
        chip.onArrowDown = { [weak self] in self?.onArrowDown?() }
        chip.onTab = { [weak self] in self?.onTab?() }
        chip.onBacktab = { [weak self] in self?.onBacktab?() }
        chip.onDragBegan = { [weak self, weak chip] in
            self?.withIndex(of: chip) { self?.drag = ($0, 0) }
        }
        chip.onDragged = { [weak self] offset in
            guard let self, let drag = self.drag else { return }
            self.drag = (drag.index, offset)
            self.needsLayout = true
        }
        chip.onDragEnded = { [weak self] in self?.endDrag() }
        return chip
    }

    private func withIndex(of chip: WorkspaceTabChip?, _ body: (Int) -> Void) {
        guard let chip, let index = chips.firstIndex(where: { $0 === chip }) else { return }
        body(index)
    }

    private func step(from index: Int, by delta: Int) {
        let next = index + delta
        guard chips.indices.contains(next) else { return }
        onSelect?(next)
        focusSelectedChip()
    }

    private func endDrag() {
        guard let drag else { return }
        let target = dropIndex(for: drag)
        self.drag = nil
        needsLayout = true
        if target != drag.index { onMove?(drag.index, target) }
    }

    private func buildRenameHint() {
        renameHint.orientation = .horizontal
        renameHint.alignment = .centerY
        renameHint.spacing = 6
        for (key, text) in [("⏎", "rename"), ("esc", "cancel")] {
            let cap = KeycapView(shortcut: key)
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = Theme.current.chrome.ink(.muted)
            hintCaps.append(cap)
            hintLabels.append(label)
            renameHint.addArrangedSubview(cap)
            renameHint.addArrangedSubview(label)
            renameHint.setCustomSpacing(12, after: label)
        }
        renameHint.translatesAutoresizingMaskIntoConstraints = true
        renameHint.isHidden = true
        addSubview(renameHint)
    }
}
