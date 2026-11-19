import AppKit

class ListRow: ControlView, HoverSuppressing, ThemeReapplying {
    enum Leading: Equatable {
        case symbol(String)
        case swatch(NSColor)
        case spinner
    }

    enum Trailing: Equatable {
        case check
        case keycap(String)
    }

    struct Content: Equatable {
        var title: String
        var subtitle: String?
        var subtitleTruncation: NSLineBreakMode
        var note: String?
        var leading: Leading?
        var trailing: Trailing?
        var ink: ChromeTheme.InkLevel
        var nests: Bool
        var titleColor: NSColor?

        init(
            title: String, subtitle: String? = nil, subtitleTruncation: NSLineBreakMode = .byTruncatingTail,
            note: String? = nil, leading: Leading? = nil, trailing: Trailing? = nil,
            ink: ChromeTheme.InkLevel = .normal, nests: Bool = false, titleColor: NSColor? = nil
        ) {
            self.title = title
            self.subtitle = subtitle
            self.subtitleTruncation = subtitleTruncation
            self.note = note
            self.leading = leading
            self.trailing = trailing
            self.ink = ink
            self.nests = nests
            self.titleColor = titleColor
        }
    }

    static let swatchSize: CGFloat = 10
    private static let symbolColumn: CGFloat = ChromeMetrics.Icon.md
    private static let noteMaxWidth: CGFloat = 96
    private static let nestIndent: CGFloat = ChromeMetrics.Spacing.s16
    private static let lineGap: CGFloat = ChromeMetrics.Spacing.s2
    private static let tallPadding: CGFloat = ChromeMetrics.Spacing.s6

    var tooltip: TooltipHost?
    private weak var subtitleLine: NSTextField?
    private let subtitleTip = TooltipHost(label: "")
    var onChoose: () -> Void
    var focusesOnClick = false
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { refreshFill() } }
    }
    var isCurrent = false {
        didSet {
            guard isCurrent != oldValue else { return }
            refreshAccessibilitySelected()
            refreshFill()
        }
    }
    private var accessoryViews: [NSView] = []
    var accessories: [NSView] {
        get { accessoryViews }
        set {
            accessoryViews = newValue
            rebuild()
        }
    }
    var footnote: NSView? {
        didSet {
            guard footnote !== oldValue else { return }
            oldValue?.removeFromSuperview()
            placeFootnote()
            refreshInsets()
        }
    }
    private(set) var content: Content
    private(set) var isTakingKeyboardFocus = false
    private(set) var isHoverSuppressed = false
    private let stack = NSStackView()
    // Kept across rebuilds, so a row that re-renders on hover keeps the label its layout and callers hold.
    private let titleLabel = NSTextField(labelWithString: "")
    // Kept across rebuilds too, or a theme change restarts its animation from the first frame.
    private lazy var spinner: Spinner = {
        let spinner = Spinner()
        spinner.isSpinning = true
        return spinner
    }()
    private lazy var stackLeading = stack.leadingAnchor.constraint(equalTo: leadingAnchor)
    private lazy var stackTop = stack.topAnchor.constraint(equalTo: topAnchor)
    private lazy var stackBottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
    private var footnoteBottom: NSLayoutConstraint?

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
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stackLeading, stackTop, stackBottom,
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChromeMetrics.Spacing.controlInset),
        ])
        setAccessibilityLabel(content.title)
        refreshAccessibilitySelected()
        rebuild()
        refreshFill()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(_ content: Content, accessories: [NSView]? = nil) {
        let accessoriesChange = accessories.map { !$0.elementsEqual(self.accessories, by: ===) } ?? false
        guard content != self.content || accessoriesChange else { return }
        if let accessories, accessoriesChange { accessoryViews = accessories }
        self.content = content
        setAccessibilityLabel(content.title)
        refreshAccessibilitySelected()
        rebuild()
    }

    func reapplyTheme() {
        rebuild()
        refreshFill()
    }

    private func refreshAccessibilitySelected() {
        setAccessibilitySelected(isCurrent || content.trailing == .check)
    }

    private func rebuild() {
        let chrome = Theme.current.chrome

        var lead: [NSView] = []
        if let leading = content.leading { lead.append(leadingView(leading, chrome)) }
        lead.append(titleView(chrome))

        var trail: [NSView] = accessoryViews
        if let note = content.note {
            let label = NSTextField(labelWithString: note)
            label.font = ChromeType.font(.caption)
            label.textColor = chrome.ink(.muted)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.noteMaxWidth).isActive = true
            trail.append(label)
        }
        if let trailing = content.trailing { trail.append(Self.trailingView(trailing, chrome)) }

        stack.setViews(lead, in: .leading)
        stack.setViews(trail, in: .trailing)
        if lead.count > 1 { stack.setCustomSpacing(ChromeMetrics.Spacing.s6, after: lead[0]) }
        for view in trail.dropLast() { stack.setCustomSpacing(ChromeMetrics.Spacing.s6, after: view) }
        refreshInsets()
    }

    private func titleView(_ chrome: ChromeTheme) -> NSView {
        let title = titleLabel
        title.stringValue = content.title
        title.font = ChromeType.font(content.nests ? .small : .body)
        title.textColor = content.titleColor ?? chrome.ink(content.ink)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        guard let subtitle = content.subtitle else { return title }

        let line = NSTextField(labelWithString: subtitle)
        subtitleLine = line
        line.font = ChromeType.font(.caption)
        line.textColor = chrome.ink(.muted)
        line.lineBreakMode = content.subtitleTruncation
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let lines = NSStackView(views: [title, line])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = Self.lineGap
        lines.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lines.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return lines
    }

    // A one-line row centers in the height its owner gives it; a taller row pads itself.
    private func refreshInsets() {
        let pad = content.subtitle != nil || footnote != nil ? Self.tallPadding : 0
        stackLeading.constant = ChromeMetrics.Spacing.controlInset + (content.nests ? Self.nestIndent : 0)
        stackTop.constant = pad
        stackBottom.constant = -pad
        footnoteBottom?.constant = -pad
    }

    private func placeFootnote() {
        footnoteBottom = nil
        guard let footnote else {
            stackBottom.isActive = true
            return
        }
        stackBottom.isActive = false
        footnote.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footnote)
        let bottom = footnote.bottomAnchor.constraint(equalTo: bottomAnchor)
        footnoteBottom = bottom
        NSLayoutConstraint.activate([
            footnote.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            footnote.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            footnote.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: Self.lineGap),
            bottom,
        ])
    }

    private func leadingView(_ leading: Leading, _ chrome: ChromeTheme) -> NSView {
        switch leading {
        case .symbol(let name):
            let icon = NSImageView()
            icon.image = IconCatalog.image(name, pointSize: ChromeMetrics.Icon.sm, weight: .regular)
            icon.contentTintColor = chrome.ink(.subtle)
            icon.widthAnchor.constraint(equalToConstant: Self.symbolColumn).isActive = true
            return icon
        case .swatch(let color):
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = ChromeMetrics.Radius.capsule(Self.swatchSize)
            dot.layer?.backgroundColor = color.cgColor
            dot.layer?.borderWidth = ChromeMetrics.Border.width
            dot.layer?.borderColor = chrome.fill(alpha: ChromeTheme.swatchRing).cgColor
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: Self.swatchSize),
                dot.heightAnchor.constraint(equalToConstant: Self.swatchSize),
            ])
            return dot
        case .spinner:
            return spinner
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

    var showsHover: Bool { isHovered && !isHoverSuppressed }

    private func refreshFill() {
        let chrome = Theme.current.chrome
        showFocusRing(hasKeyboardFocus)
        if showsHover || isHighlighted {
            easeFill(chrome.fill(.hover))
        } else if isCurrent {
            easeFill(chrome.fill(.active))
        } else {
            easeFill(.clear)
        }
    }

    // AppKit promotes any clicked view that accepts, so a keyboard-only row accepts only in `takeKeyboardFocus`.
    override var acceptsFirstResponder: Bool { focusesOnClick || isTakingKeyboardFocus }

    func takeKeyboardFocus() {
        isTakingKeyboardFocus = true
        window?.makeFirstResponder(self)
        isTakingKeyboardFocus = false
    }

    override func focusDidChange() { refreshFill() }

    override func hoverDidChange() {
        if !isHovered { hideTooltip() }
        refreshFill()
    }

    // A list with a keyboard cursor suppresses hover too, or the hovered row and the cursor's row would both look chosen.
    func setHoverSuppressed(_ suppressed: Bool) {
        guard suppressed != isHoverSuppressed else { return }
        isHoverSuppressed = suppressed
        if suppressed { hideTooltip() } else { refreshHover() }
        hoverDidChange()
    }

    // A truncated subtitle shows in full on hover, unless the owner gave the row a tooltip of its own.
    private var hoverTooltip: TooltipHost? {
        if let tooltip { return tooltip }
        guard let line = subtitleLine, line.bounds.width < line.intrinsicContentSize.width else { return nil }
        subtitleTip.label = line.stringValue
        return subtitleTip
    }

    private func hideTooltip() { TooltipPresenter.shared.hide(for: self) }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isHoverSuppressed else { return }
        hoverTooltip?.show(from: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hideTooltip() }
    }

    override func mouseDown(with event: NSEvent) {
        hideTooltip()
        if focusesOnClick { window?.makeFirstResponder(self) }
        onChoose()
    }

    override func accessibilityPerformPress() -> Bool {
        onChoose()
        return true
    }
}
