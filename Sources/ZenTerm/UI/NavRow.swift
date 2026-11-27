import AppKit

final class NavRow: ListRow {
    enum Variant: Equatable {
        case standard
        case leading(ProcessIcon)
        case nested(ProcessIcon)
        case faint(ProcessIcon)
    }

    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onEnterDetail: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onFocusChanged: (() -> Void)?

    var variant: Variant {
        didSet { if variant != oldValue { refreshContent() } }
    }
    private var detail: String?
    var spokenStatus: String? {
        didSet { if spokenStatus != oldValue { refreshContent() } }
    }
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
        switch variant {
        case .leading(let process), .faint(let process):
            next.leading = .process(process)
        case .nested(let process):
            next.leading = .process(process)
            next.nesting = .underTitle
        case .standard:
            break
        }
        render(next, accessories: shown)
        setAccessibilityValue(detail?.isEmpty == false ? detail : spokenStatus)
    }

    private var titleInkLevel: ChromeTheme.InkLevel {
        if let titleInk { return titleInk }
        switch variant {
        case .standard, .leading: return .normal
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
