import AppKit

final class NavRow: ListRow {
    enum Variant: Equatable {
        case standard
        case nested(symbol: String)
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
    private let attentionDot = NSView()
    private var dotInk: (() -> NSColor)?
    private var dotAccessibilityValue: String?
    private(set) var hoverAccessory: NSView?

    private static let attentionDotDiameter: CGFloat = 6

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
        attentionDot.wantsLayer = true
        attentionDot.layer?.cornerRadius = ChromeMetrics.Radius.capsule(Self.attentionDotDiameter)
        NSLayoutConstraint.activate([
            attentionDot.widthAnchor.constraint(equalToConstant: Self.attentionDotDiameter),
            attentionDot.heightAnchor.constraint(equalToConstant: Self.attentionDotDiameter),
            heightAnchor.constraint(equalToConstant: ChromeMetrics.Height.control),
        ])
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

    func setDot(_ ink: (() -> NSColor)?, accessibilityValue: String?) {
        dotInk = ink
        dotAccessibilityValue = ink == nil ? nil : accessibilityValue
        attentionDot.layer?.backgroundColor = ink?().cgColor
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
        if dotInk != nil { shown.append(attentionDot) }
        if showsHoverAccessory, let hoverAccessory { shown.append(hoverAccessory) }
        var next = Content(title: content.title, note: showsHoverAccessory ? nil : detail, ink: titleInkLevel)
        if case .nested(let symbol) = variant {
            next.leading = .symbol(symbol)
            next.nests = true
        }
        render(next, accessories: shown)
        let value = [detail ?? "", dotAccessibilityValue ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
        setAccessibilityValue(value.isEmpty ? nil : value)
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

    var showsAttentionForTesting: Bool { accessories.contains(attentionDot) }

    var dotColorForTesting: CGColor? { dotInk == nil ? nil : attentionDot.layer?.backgroundColor }

    override func reapplyTheme() {
        attentionDot.layer?.backgroundColor = dotInk?().cgColor
        if let hoverAccessory, hoverAccessory.superview == nil { hoverAccessory.reapplyThemeTree() }
        super.reapplyTheme()
    }

    override func focusDidChange() {
        super.focusDidChange()
        onFocusChanged?()
    }

    override func hoverDidChange() {
        super.hoverDidChange()
        if hoverAccessory != nil { refreshContent() }
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
