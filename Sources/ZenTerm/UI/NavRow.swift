import AppKit

final class NavRow: ListRow {
    enum Variant: Equatable {
        case standard
        case nested(ProcessIcon)
        case faint
    }

    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onEnterDetail: (() -> Void)?
    var onSecondaryClick: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onFocusChanged: (() -> Void)?

    let variant: Variant
    private var detail: String?
    private var titleInk: ChromeTheme.InkLevel?
    private(set) var hoverAccessory: NSView?

    override var isCurrent: Bool {
        didSet { if isCurrent != oldValue { refreshContent() } }
    }

    init(
        title: String, variant: Variant = .standard, focusesOnClick: Bool = true,
        onActivate: @escaping () -> Void
    ) {
        self.variant = variant
        super.init(ListRow.Content(title: title), onChoose: onActivate)
        self.focusesOnClick = focusesOnClick
        setAccessibilityRole(.button)
        heightAnchor.constraint(equalToConstant: ChromeMetrics.Height.control).isActive = true
        refreshContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setTitle(_ title: String) {
        var next = content
        next.title = title
        render(next)
    }

    func setDetail(_ detail: String?) {
        self.detail = detail
        refreshContent()
    }

    func setTitleInk(_ ink: ChromeTheme.InkLevel?) {
        titleInk = ink
        refreshContent()
    }

    func setHoverAccessory(_ accessory: NSView?) {
        guard accessory !== hoverAccessory else { return }
        hoverAccessory = accessory
        refreshContent()
    }

    private var showsHoverAccessory: Bool { showsHover && hoverAccessory != nil }

    private func refreshContent() {
        var shown: [NSView] = []
        if showsHoverAccessory, let hoverAccessory { shown.append(hoverAccessory) }
        var next = Content(title: content.title, note: showsHoverAccessory ? nil : detail, ink: titleInkLevel)
        if case .nested(let process) = variant {
            next.leading = .process(process)
            next.nests = true
        }
        render(next, accessories: shown)
        setAccessibilityValue(detail?.isEmpty == false ? detail : nil)
    }

    private var titleInkLevel: ChromeTheme.InkLevel {
        if let titleInk { return titleInk }
        switch variant {
        case .standard: return .normal
        case .nested: return isCurrent ? .normal : .subtle
        case .faint: return .faint
        }
    }

    var titleForTesting: String { content.title }

    var titleInkForTesting: NSColor? {
        func labels(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { (($0 as? NSTextField).map { [$0] } ?? []) + labels(in: $0) }
        }
        return labels(in: self).first { $0.stringValue == content.title }?.textColor
    }

    var detailForTesting: String { detail ?? "" }

    override func reapplyTheme() {
        if let hoverAccessory, hoverAccessory.superview == nil { hoverAccessory.reapplyThemeTree() }
        super.reapplyTheme()
    }

    override func focusDidChange() {
        super.focusDidChange()
        onFocusChanged?()
    }

    // A click can follow hover in the same turn, before a layout pass would place the accessory it just showed.
    override func hoverDidChange() {
        super.hoverDidChange()
        guard hoverAccessory != nil else { return }
        refreshContent()
        layoutSubtreeIfNeeded()
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control), let onSecondaryClick else { return super.mouseDown(with: event) }
        tooltip?.hide(from: self)
        onSecondaryClick()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onSecondaryClick else { return super.rightMouseDown(with: event) }
        tooltip?.hide(from: self)
        onSecondaryClick()
    }

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .up: onArrowUp?()
        case .tab(shift: true): onBacktab?()
        case .down: onArrowDown?()
        case .right, .tab(shift: false): onEnterDetail?()
        case .activate where onReturn != nil && KeyboardFocus.isReturn(event): onReturn?()
        case .escape where onEscape != nil && KeyboardFocus.isUnmodified(event): onEscape?()
        default: super.keyDown(with: event)
        }
    }
}
