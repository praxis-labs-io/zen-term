import AppKit

// Chips are framed by hand so a dragged chip can leave its slot while the others close the gap.
final class WorkspaceTabStrip: NSView {
    private static let chipSpacing: CGFloat = 4
    private static let addSize: CGFloat = 26
    private static let hintGap: CGFloat = 8
    private static let hintHeight: CGFloat = 20

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
    private var revealsSelection = false
    private let scrollView = NSScrollView()
    private let docView = FlippedView()
    private let edgeFade = EdgeFade(axis: .horizontal)
    private var drag: (index: Int, offset: CGFloat)?
    private lazy var addButton = IconButton(
        symbol: "plus", size: NSSize(width: Self.addSize, height: Self.addSize), pointSize: 12,
        accessibilityLabel: "Add tab", shortcut: { CommandCatalog.spec(for: .newTab).shortcut }
    ) { [weak self] in self?.onAdd?() }
    private let idleHint = NSStackView()
    private let renameHint = NSStackView()
    private var hintLabels: [NSTextField] = []
    private var hintCaps: [KeycapView] = []

    var addButtonForTesting: IconButton { addButton }
    var isRenameHintVisibleForTesting: Bool { !renameHint.isHidden }
    var isIdleHintVisibleForTesting: Bool { !idleHint.isHidden }
    var visibleChipsRectForTesting: CGRect { scrollView.contentView.documentVisibleRect }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = .init()
        scrollView.documentView = docView
        scrollView.layer?.mask = edgeFade.layer
        addSubview(scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        addButton.translatesAutoresizingMaskIntoConstraints = true
        addSubview(addButton)
        buildRenameHint()
        heightAnchor.constraint(equalToConstant: WorkspaceTabChip.height + Self.hintGap + Self.hintHeight)
            .isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var selectedChip: WorkspaceTabChip? { chips.indices.contains(selected) ? chips[selected] : nil }

    var isRenaming: Bool { chips.contains(where: \.isRenaming) }

    func render(_ form: WorkspaceForm) {
        if chips.count != form.tabs.count { revealsSelection = true }
        while chips.count < form.tabs.count { chips.append(makeChip()) }
        while chips.count > form.tabs.count { chips.removeLast().removeFromSuperview() }
        if selected != form.selected { revealsSelection = true }
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

    func commitRename() { chips.forEach { $0.commitRename() } }

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
        let contentWidth = max(0, x - Self.chipSpacing)
        let addX = max(0, bounds.width - Self.addSize)
        let visibleWidth = min(contentWidth, max(0, addX - Self.chipSpacing))
        scrollView.frame = CGRect(x: 0, y: 0, width: visibleWidth, height: WorkspaceTabChip.height)
        docView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: WorkspaceTabChip.height)
        addButton.frame = CGRect(x: addX, y: 0, width: Self.addSize, height: Self.addSize)
        renameHint.isHidden = !isRenaming
        idleHint.isHidden = isRenaming
        for hint in [idleHint, renameHint] {
            let size = hint.fittingSize
            hint.frame = CGRect(
                x: 0, y: WorkspaceTabChip.height + Self.hintGap + (Self.hintHeight - size.height) / 2,
                width: size.width, height: size.height)
        }
        if let chip = chips.first(where: \.isRenaming) ?? (revealsSelection ? selectedChip : nil) {
            chip.scrollToVisible(chip.bounds.insetBy(dx: -TabBarView.fadeWidth, dy: 0))
        }
        revealsSelection = false
        clampScrollIfContentFits()
        updateFade()
        refreshHover()
    }

    @objc private func clipBoundsChanged() {
        updateFade()
        refreshHover()
    }

    // Per-chip tracking areas miss `mouseExited` when chips move or scroll under a stationary pointer.
    private func refreshHover() {
        guard let window, window.isKeyWindow else { return chips.forEach { $0.setHover(false) } }
        let pointer = window.mouseLocationOutsideOfEventStream
        let visible = scrollView.contentView.documentVisibleRect
        for chip in chips {
            chip.setHover(chip.frame.intersects(visible) && chip.convert(chip.bounds, to: nil).contains(pointer))
        }
    }

    private func clampScrollIfContentFits() {
        let clip = scrollView.contentView
        guard docView.frame.width <= clip.bounds.width, clip.bounds.origin.x > 0 else { return }
        clip.scroll(to: .zero)
        scrollView.reflectScrolledClipView(clip)
    }

    private func updateFade() {
        let clip = scrollView.contentView
        let leftOverflow = clip.bounds.origin.x > 0.5
        let rightOverflow = docView.frame.width - (clip.bounds.origin.x + clip.bounds.width) > 0.5
        let width = scrollView.bounds.width > 2 * TabBarView.fadeWidth ? TabBarView.fadeWidth : 0
        edgeFade.update(
            frame: scrollView.bounds, start: leftOverflow ? width : 0, end: rightOverflow ? width : 0)
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
        docView.addSubview(chip)
        chip.onSelect = { [weak self, weak chip] in
            guard let self, let chip, let index = self.chips.firstIndex(where: { $0 === chip }) else { return }
            self.onSelect?(index)
        }
        chip.onRemove = { [weak self, weak chip] in self?.withIndex(of: chip) { self?.onRemove?($0) } }
        chip.onRename = { [weak self, weak chip] name in self?.withIndex(of: chip) { self?.onRename?($0, name) } }
        chip.onRenamingChanged = { [weak self] in
            guard let self else { return }
            self.renameHint.isHidden = !self.isRenaming
            self.idleHint.isHidden = self.isRenaming
            self.needsLayout = true
        }
        chip.onWidthChanged = { [weak self] in self?.needsLayout = true }
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
        fill(idleHint, with: [.text("Double-click or"), .key("⏎"), .text("to rename a tab")])
        fill(renameHint, with: [.key("⏎"), .text("rename"), .gap, .key("esc"), .text("cancel")])
        renameHint.isHidden = true
    }

    private enum HintPart {
        case key(String)
        case text(String)
        case gap
    }

    private func fill(_ hint: NSStackView, with parts: [HintPart]) {
        hint.orientation = .horizontal
        hint.alignment = .centerY
        hint.spacing = 6
        for part in parts {
            switch part {
            case .key(let key):
                let cap = KeycapView(shortcut: key)
                hintCaps.append(cap)
                hint.addArrangedSubview(cap)
            case .text(let text):
                let label = NSTextField(labelWithString: text)
                label.font = .systemFont(ofSize: 11)
                label.textColor = Theme.current.chrome.ink(.muted)
                hintLabels.append(label)
                hint.addArrangedSubview(label)
            case .gap:
                if let last = hint.arrangedSubviews.last { hint.setCustomSpacing(12, after: last) }
            }
        }
        hint.translatesAutoresizingMaskIntoConstraints = true
        addSubview(hint)
    }
}
