import AppKit

final class SettingsNavRow: NSView, HoverSuppressing {
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
    var tooltip: TooltipHost?

    let variant: Variant
    private let label = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let glyph = NSImageView()
    private let attentionDot = NSView()
    private var attentionDotWidth: NSLayoutConstraint?
    private var attentionDotGap: NSLayoutConstraint?
    private let onActivate: () -> Void
    private let focusesOnClick: Bool
    private var isTakingKeyboardFocus = false
    private var trackingArea: NSTrackingArea?
    private var isSelected = false
    private var isFocusedStop = false
    private var isHoverSuppressed = false
    var onFocusChanged: (() -> Void)?
    private var isHovered = false { didSet { refreshAccessory() } }
    private(set) var hoverAccessory: NSView?

    private static let detailMaxWidth: CGFloat = 96
    private static let nestedIndent: CGFloat = 24
    private static let nestedGlyphGap: CGFloat = 6
    private static let nestedGlyphSize: CGFloat = 11
    // The frame pulls a 20pt accessory 5pt past the detail's inset, so its glyph sits where the detail ends.
    private static let accessoryInset: CGFloat = 5
    private static let attentionDotDiameter: CGFloat = 6
    private static let attentionDotGapToDetail: CGFloat = 6
    private static let attentionAccessibilityValue = "Agent waiting"

    init(
        title: String, variant: Variant = .standard, focusesOnClick: Bool = true,
        onActivate: @escaping () -> Void
    ) {
        self.onActivate = onActivate
        self.focusesOnClick = focusesOnClick
        self.variant = variant
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        label.stringValue = title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.alignment = .right
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)
        attentionDot.wantsLayer = true
        attentionDot.layer?.cornerRadius = Self.attentionDotDiameter / 2
        attentionDot.isHidden = true
        attentionDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(attentionDot)
        let dotWidth = attentionDot.widthAnchor.constraint(equalToConstant: 0)
        let dotGap = attentionDot.trailingAnchor.constraint(equalTo: detailLabel.leadingAnchor)
        attentionDotWidth = dotWidth
        attentionDotGap = dotGap
        NSLayoutConstraint.activate([
            dotWidth,
            dotGap,
            attentionDot.heightAnchor.constraint(equalToConstant: Self.attentionDotDiameter),
            attentionDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: attentionDot.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.detailMaxWidth),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if case .nested(let symbol) = variant {
            installGlyph(symbol)
        } else {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                heightAnchor.constraint(equalToConstant: 30),
            ])
        }
        reapplyTheme()
    }

    private func installGlyph(_ symbol: String) {
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        glyph.symbolConfiguration = .init(pointSize: Self.nestedGlyphSize, weight: .regular)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        label.font = .systemFont(ofSize: 12)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.nestedIndent),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: Self.nestedGlyphGap),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        setAccessibilitySelected(selected)
        refreshLabelInk()
        refreshFill()
    }

    func setHoverAccessory(_ accessory: NSView?) {
        guard accessory !== hoverAccessory else { return }
        hoverAccessory?.removeFromSuperview()
        hoverAccessory = accessory
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.accessoryInset),
                accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        refreshAccessory()
    }

    private func refreshAccessory() {
        hoverAccessory?.isHidden = !showsHover
        detailLabel.isHidden = showsHover && hoverAccessory != nil
    }

    func setTitle(_ title: String) {
        label.stringValue = title
        setAccessibilityLabel(title)
    }

    func setDetail(_ detail: String?) {
        detailLabel.stringValue = detail ?? ""
        refreshAccessibilityValue()
    }

    func setShowsAttention(_ shows: Bool) {
        attentionDot.isHidden = !shows
        attentionDotWidth?.constant = shows ? Self.attentionDotDiameter : 0
        attentionDotGap?.constant = shows ? -Self.attentionDotGapToDetail : 0
        refreshAccessibilityValue()
    }

    private func refreshAccessibilityValue() {
        let parts = [detailLabel.stringValue, attentionDot.isHidden ? "" : Self.attentionAccessibilityValue]
        let value = parts.filter { !$0.isEmpty }.joined(separator: ", ")
        setAccessibilityValue(value.isEmpty ? nil : value)
    }

    var titleForTesting: String { label.stringValue }

    var titleInkForTesting: NSColor? { label.textColor }

    var detailForTesting: String { detailLabel.stringValue }

    var showsAttentionForTesting: Bool { !attentionDot.isHidden }

    func reapplyTheme() {
        refreshLabelInk()
        detailLabel.textColor = Theme.current.chrome.ink(.muted)
        glyph.contentTintColor = Theme.current.chrome.ink(.faint)
        attentionDot.layer?.backgroundColor = Theme.current.chrome.attention.nsColor.cgColor
        refreshFill()
    }

    private func refreshLabelInk() {
        let chrome = Theme.current.chrome
        switch variant {
        case .standard: label.textColor = chrome.foreground.nsColor
        case .nested: label.textColor = chrome.ink(isSelected ? .normal : .subtle)
        case .faint: label.textColor = chrome.ink(.faint)
        }
    }

    private var showsHover: Bool { isHovered && !isHoverSuppressed }

    private func refreshFill() {
        if isFocusedStop {
            layer?.backgroundColor = Theme.current.chrome.selectionFill.cgColor
        } else if showsHover {
            layer?.backgroundColor = Theme.current.chrome.fill(.hover).cgColor
        } else if isSelected {
            layer?.backgroundColor = Theme.current.chrome.fill(.rest).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    // AppKit promotes any clicked view that accepts, so a keyboard-only row accepts only in `takeKeyboardFocus`.
    override var acceptsFirstResponder: Bool { focusesOnClick || isTakingKeyboardFocus }

    func takeKeyboardFocus() {
        isTakingKeyboardFocus = true
        window?.makeFirstResponder(self)
        isTakingKeyboardFocus = false
    }
    override func becomeFirstResponder() -> Bool {
        isFocusedStop = true
        refreshFill()
        onFocusChanged?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFocusedStop = false
        refreshFill()
        onFocusChanged?()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshFill()
        guard !isHoverSuppressed else { return }
        tooltip?.show(from: self)
    }

    func setHoverSuppressed(_ suppressed: Bool) {
        guard suppressed != isHoverSuppressed else { return }
        isHoverSuppressed = suppressed
        if suppressed { tooltip?.hide(from: self) } else { isHovered = pointerIsInside }
        refreshAccessory()
        refreshFill()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshFill()
        tooltip?.hide(from: self)
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
        refreshFill()
        tooltip?.hide(from: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tooltip?.hide(from: self) }
    }

    override func accessibilityPerformPress() -> Bool { onActivate(); return true }

    override func mouseDown(with event: NSEvent) {
        tooltip?.hide(from: self)
        if event.modifierFlags.contains(.control), let onSecondaryClick { return onSecondaryClick() }
        if focusesOnClick { window?.makeFirstResponder(self) }
        onActivate()
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
