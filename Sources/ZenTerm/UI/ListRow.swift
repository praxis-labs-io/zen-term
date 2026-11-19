import AppKit

final class ListRow: ControlView, ThemeReapplying {
    enum Leading: Equatable {
        case symbol(String)
        case swatch(NSColor)
    }

    enum Trailing: Equatable {
        case check
        case keycap(String)
    }

    struct Content: Equatable {
        var title: String
        var note: String?
        var leading: Leading?
        var trailing: Trailing?
        var recedes: Bool

        init(
            title: String, note: String? = nil, leading: Leading? = nil, trailing: Trailing? = nil,
            recedes: Bool = false
        ) {
            self.title = title
            self.note = note
            self.leading = leading
            self.trailing = trailing
            self.recedes = recedes
        }
    }

    static let swatchSize: CGFloat = 10
    private static let symbolColumn: CGFloat = ChromeMetrics.Icon.md

    var tooltip: TooltipHost?
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { refreshFill() } }
    }
    // A list with a keyboard cursor turns this off, or the hovered row and the cursor's row would both look chosen.
    var hoverFills = true {
        didSet { refreshFill() }
    }
    private(set) var content: Content
    private(set) var isTakingKeyboardFocus = false
    private let onChoose: () -> Void
    private let stack = NSStackView()

    var title: String { content.title }

    var shortcutForTesting: String {
        guard case .keycap(let shortcut) = content.trailing else { return "" }
        return shortcut
    }

    init(_ content: Content, onChoose: @escaping () -> Void) {
        self.content = content
        self.onChoose = onChoose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.control
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = ChromeMetrics.Spacing.s8
        stack.edgeInsets = NSEdgeInsets(
            top: 0, left: ChromeMetrics.Spacing.controlInset, bottom: 0, right: ChromeMetrics.Spacing.controlInset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        rebuild()
        refreshFill()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(_ content: Content) {
        guard content != self.content else { return }
        self.content = content
        rebuild()
    }

    func reapplyTheme() {
        rebuild()
        refreshFill()
    }

    private func rebuild() {
        let chrome = Theme.current.chrome
        setAccessibilityLabel(content.title)
        setAccessibilitySelected(content.trailing == .check)

        let title = NSTextField(labelWithString: content.title)
        title.font = ChromeType.font(.body)
        title.textColor = chrome.ink(content.recedes ? .muted : .normal)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var lead: [NSView] = []
        if let leading = content.leading { lead.append(Self.leadingView(leading, chrome)) }
        lead.append(title)

        var trail: [NSView] = []
        if let note = content.note {
            let label = NSTextField(labelWithString: note)
            label.font = ChromeType.font(.caption)
            label.textColor = chrome.ink(.muted)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            trail.append(label)
        }
        if let trailing = content.trailing { trail.append(Self.trailingView(trailing, chrome)) }

        stack.setViews(lead, in: .leading)
        stack.setViews(trail, in: .trailing)
        if lead.count > 1 { stack.setCustomSpacing(ChromeMetrics.Spacing.s6, after: lead[0]) }
        if trail.count > 1 { stack.setCustomSpacing(ChromeMetrics.Spacing.s6, after: trail[0]) }
    }

    private static func leadingView(_ leading: Leading, _ chrome: ChromeTheme) -> NSView {
        switch leading {
        case .symbol(let name):
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: ChromeMetrics.Icon.sm, weight: .regular)
            icon.contentTintColor = chrome.ink(.subtle)
            icon.widthAnchor.constraint(equalToConstant: symbolColumn).isActive = true
            return icon
        case .swatch(let color):
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = ChromeMetrics.Radius.capsule(swatchSize)
            dot.layer?.backgroundColor = color.cgColor
            dot.layer?.borderWidth = ChromeMetrics.Border.width
            dot.layer?.borderColor = chrome.fill(alpha: ChromeTheme.swatchRing).cgColor
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: swatchSize),
                dot.heightAnchor.constraint(equalToConstant: swatchSize),
            ])
            return dot
        }
    }

    private static func trailingView(_ trailing: Trailing, _ chrome: ChromeTheme) -> NSView {
        switch trailing {
        case .check:
            let check = NSImageView()
            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            check.symbolConfiguration = .init(pointSize: ChromeMetrics.Icon.sm, weight: .semibold)
            check.contentTintColor = chrome.ink(.normal)
            return check
        case .keycap(let shortcut):
            return KeycapView(shortcut: shortcut)
        }
    }

    private func refreshFill() {
        showFocusRing(hasKeyboardFocus)
        easeFill((isHovered && hoverFills) || isHighlighted ? Theme.current.chrome.fill(.hover) : .clear)
    }

    // AppKit promotes any clicked view that accepts, so a row accepts only in `takeKeyboardFocus`.
    override var acceptsFirstResponder: Bool { isTakingKeyboardFocus }

    func takeKeyboardFocus() {
        isTakingKeyboardFocus = true
        window?.makeFirstResponder(self)
        isTakingKeyboardFocus = false
    }

    override func focusDidChange() { refreshFill() }

    override func hoverDidChange() {
        if !isHovered { tooltip?.hide(from: self) }
        refreshFill()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        tooltip?.show(from: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tooltip?.hide(from: self) }
    }

    override func mouseDown(with event: NSEvent) {
        tooltip?.hide(from: self)
        onChoose()
    }

    override func accessibilityPerformPress() -> Bool {
        onChoose()
        return true
    }
}
