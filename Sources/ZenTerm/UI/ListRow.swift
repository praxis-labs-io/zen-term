import AppKit

class ListRow: ControlView, ThemeReapplying {
    enum Leading: Equatable {
        case symbol(String)
        case swatch(NSColor)
        case spinner
        case process(ProcessIcon)
    }

    enum Trailing: Equatable {
        case check
        case keycap(String)
    }

    enum Nesting: Equatable {
        case none
        case indented
        // The glyph starts where the parent's title does, under a parent that leads with the same glyph.
        case underTitle
    }

    struct Content: Equatable {
        var title: String
        var subtitle: String?
        var subtitleTruncation: NSLineBreakMode
        var note: String?
        var titleSuffix: String?
        var leading: Leading?
        var trailing: Trailing?
        var ink: ChromeTheme.InkLevel
        var nesting: Nesting
        var leadingOnTitleLine: Bool
        // The subtitle's descent hangs into the bottom padding, so the row's ink sits as far from its bottom as its top.
        var trimsSubtitleDescent: Bool

        init(
            title: String, subtitle: String? = nil, subtitleTruncation: NSLineBreakMode = .byTruncatingTail,
            note: String? = nil, titleSuffix: String? = nil, leading: Leading? = nil, trailing: Trailing? = nil,
            ink: ChromeTheme.InkLevel = .normal, nesting: Nesting = .none, leadingOnTitleLine: Bool = false,
            trimsSubtitleDescent: Bool = false
        ) {
            self.title = title
            self.subtitle = subtitle
            self.subtitleTruncation = subtitleTruncation
            self.note = note
            self.titleSuffix = titleSuffix
            self.leading = leading
            self.trailing = trailing
            self.ink = ink
            self.nesting = nesting
            self.leadingOnTitleLine = leadingOnTitleLine
            self.trimsSubtitleDescent = trimsSubtitleDescent
        }

        var nests: Bool { nesting != .none }
    }

    static let swatchSize: CGFloat = 10
    private static let symbolColumn: CGFloat = ChromeMetrics.Icon.md
    private static let noteMaxWidth: CGFloat = 96
    private static let nestStep: CGFloat = ChromeMetrics.Spacing.s16
    private static let lineGap: CGFloat = ChromeMetrics.Spacing.s2
    private static let tallPadding: CGFloat = ChromeMetrics.Spacing.s6

    var tooltip: TooltipHost?
    private weak var subtitleLine: NSTextField?
    private let subtitleTip = TooltipHost(label: "")
    var onChoose: () -> Void
    var onSecondaryClick: (() -> Void)?
    var onSpace: (() -> Void)?
    // The pointer moves a list's cursor instead of filling its own row, or two rows would look chosen.
    var onPointerEnter: (() -> Void)? {
        didSet { refreshFill() }
    }
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
    private var isPressed = false
    private let stack = NSStackView()
    // Kept across rebuilds, so a row that re-renders on hover keeps the label its layout and callers hold.
    private let titleLabel = NSTextField(labelWithString: "")
    // Kept across rebuilds too, or a theme change restarts its animation from the first frame.
    private lazy var spinner: Spinner = {
        let spinner = Spinner()
        spinner.isSpinning = true
        return spinner
    }()
    // Kept too, so a program change crossfades the mark rather than swapping in a new chip.
    private var processBadge: IconBadge?
    private lazy var stackLeading = stack.leadingAnchor.constraint(equalTo: leadingAnchor)
    private lazy var stackTop = stack.topAnchor.constraint(equalTo: topAnchor)
    private lazy var stackBottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
    private var footnoteBottom: NSLayoutConstraint?
    // Pinned again on every rebuild: moving the title into a new lines stack drops constraints on it.
    private var titleLineViews: [NSView] = []
    private var titleLinePins: [NSLayoutConstraint] = []
    private var nestIndent: CGFloat = 0

    var title: String { content.title }

    var trimmedSubtitleDescent: CGFloat {
        guard content.trimsSubtitleDescent, content.subtitle != nil, let subtitleLine else { return 0 }
        let scale = window?.backingScaleFactor ?? 2
        return (subtitleLine.lastBaselineOffsetFromBottom * scale).rounded() / scale
    }

    var titleLabelForTesting: NSTextField { titleLabel }

    var subtitleLineForTesting: NSTextField? { subtitleLine }

    var processBadgeForTesting: IconBadge? {
        guard case .process = content.leading else { return nil }
        return processBadge
    }

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

    func centerOnTitleLine(_ views: [NSView]) {
        titleLineViews = views
        pinTitleLine()
    }

    private func pinTitleLine() {
        NSLayoutConstraint.deactivate(titleLinePins)
        titleLinePins = titleLineViews.map { $0.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor) }
        NSLayoutConstraint.activate(titleLinePins)
    }

    private func refreshAccessibilitySelected() {
        setAccessibilitySelected(isCurrent || content.trailing == .check)
    }

    private func rebuild() {
        let chrome = Theme.current.chrome

        let glyph = content.leading.map { leadingView($0, chrome) }
        nestIndent = Self.nestIndent(content.nesting, glyph: glyph)
        var lead: [NSView] = []
        if content.leadingOnTitleLine, content.subtitle != nil, let glyph {
            lead.append(titleView(chrome, leading: glyph))
        } else {
            if let glyph { lead.append(glyph) }
            lead.append(titleView(chrome))
        }

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
        pinTitleLine()
    }

    private func titleView(_ chrome: ChromeTheme, leading glyph: NSView? = nil) -> NSView {
        let title = titleLabel
        title.stringValue = content.title
        title.font = ChromeType.font(content.nests ? .small : .body)
        title.textColor = chrome.ink(content.ink)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let head = content.titleSuffix.map { Self.suffixed(title, with: $0, chrome) } ?? title
        guard let subtitle = content.subtitle else { return head }

        let line = NSTextField(labelWithString: subtitle)
        subtitleLine = line
        line.font = ChromeType.font(.caption)
        line.textColor = chrome.ink(.muted)
        line.lineBreakMode = content.subtitleTruncation
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let lines = NSStackView(views: [
            glyph.map { Self.titleLine(leading: $0, title: head) } ?? head,
            glyph.map { Self.indented(line, past: $0) } ?? line,
        ])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = Self.lineGap
        lines.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lines.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return lines
    }

    // The second line starts where the title's text does, not under the glyph.
    private static func indented(_ line: NSTextField, past glyph: NSView) -> NSView {
        let inset = NSStackView(views: [line])
        inset.edgeInsets = NSEdgeInsets(top: 0, left: glyph.fittingSize.width + titleLineGap, bottom: 0, right: 0)
        inset.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inset.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return inset
    }

    private static let titleLineGap = ChromeMetrics.Spacing.s6

    private static func nestIndent(_ nesting: Nesting, glyph: NSView?) -> CGFloat {
        switch nesting {
        case .none: return 0
        case .indented: return nestStep
        case .underTitle: return (glyph?.fittingSize.width ?? 0) + titleLineGap
        }
    }

    private static func suffixed(_ title: NSTextField, with suffix: String, _ chrome: ChromeTheme) -> NSView {
        let label = NSTextField(labelWithString: suffix)
        label.font = ChromeType.font(.caption)
        label.textColor = chrome.ink(.muted)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let line = NSStackView(views: [title, label])
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = titleLineGap
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        line.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return line
    }

    private static func titleLine(leading glyph: NSView, title: NSView) -> NSView {
        let line = NSStackView(views: [glyph, title])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = titleLineGap
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        line.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return line
    }

    // A one-line row centers in the height its owner gives it; a taller row pads itself.
    private func refreshInsets() {
        let pad = content.subtitle != nil || footnote != nil ? Self.tallPadding : 0
        stackLeading.constant = ChromeMetrics.Spacing.controlInset + nestIndent
        stackTop.constant = pad
        stackBottom.constant = trimmedSubtitleDescent - pad
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
        case .process(let process):
            if let processBadge {
                processBadge.show(process)
                processBadge.reapplyTheme()
                return processBadge
            }
            let badge = IconBadge(process: process, size: .small)
            processBadge = badge
            return badge
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

    override var showsHover: Bool { super.showsHover && onPointerEnter == nil }

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
        if !isHovered {
            hideTooltip()
        } else if !isHoverSuppressed, PointerRest.claimPointerMove() {
            onPointerEnter?()
        }
        if isHoverSuppressed { hideTooltip() }
        refreshFill()
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
        guard !isHoverSuppressed, onPointerEnter == nil else { return }
        hoverTooltip?.show(from: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hideTooltip() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshInsets()
    }

    override func mouseDown(with event: NSEvent) {
        hideTooltip()
        if event.modifierFlags.contains(.control), let onSecondaryClick { return onSecondaryClick() }
        isPressed = true
        if focusesOnClick { window?.makeFirstResponder(self) }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onSecondaryClick else { return super.rightMouseDown(with: event) }
        hideTooltip()
        onSecondaryClick()
    }

    override func keyDown(with event: NSEvent) {
        guard let onSpace, KeyboardFocus.key(for: event) == .activate, KeyboardFocus.isSpace(event) else {
            return super.keyDown(with: event)
        }
        onSpace()
    }

    // A control inside the row that acts on its press passes the release up the responder chain to here.
    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onChoose()
    }

    override func accessibilityPerformPress() -> Bool {
        onChoose()
        return true
    }
}
