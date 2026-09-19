import AppKit

final class SettingsNavRow: NSView {
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onEnterDetail: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var tooltip: TooltipHost?

    private let label = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let attentionDot = NSView()
    private var attentionDotWidth: NSLayoutConstraint?
    private var attentionDotGap: NSLayoutConstraint?
    private let onActivate: () -> Void
    private let focusesOnClick: Bool
    private var isTakingKeyboardFocus = false
    private var trackingArea: NSTrackingArea?
    private var isSelected = false
    private var isFocusedStop = false
    private var isHovered = false

    private static let detailMaxWidth: CGFloat = 96
    private static let attentionDotDiameter: CGFloat = 6
    private static let attentionDotGapToDetail: CGFloat = 6
    private static let attentionAccessibilityValue = "Agent waiting"

    init(title: String, focusesOnClick: Bool = true, onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        self.focusesOnClick = focusesOnClick
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
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: attentionDot.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.detailMaxWidth),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        setAccessibilitySelected(selected)
        refreshFill()
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

    var detailForTesting: String { detailLabel.stringValue }

    var showsAttentionForTesting: Bool { !attentionDot.isHidden }

    func reapplyTheme() {
        label.textColor = Theme.current.chrome.foreground.nsColor
        detailLabel.textColor = Theme.current.chrome.ink(.muted)
        attentionDot.layer?.backgroundColor = Theme.current.chrome.attention.nsColor.cgColor
        refreshFill()
    }

    private func refreshFill() {
        if isFocusedStop {
            layer?.backgroundColor = Theme.current.chrome.selectionFill.cgColor
        } else if isHovered {
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
    override func becomeFirstResponder() -> Bool { isFocusedStop = true; refreshFill(); return true }
    override func resignFirstResponder() -> Bool { isFocusedStop = false; refreshFill(); return true }

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
        tooltip?.show(from: self)
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
        if focusesOnClick { window?.makeFirstResponder(self) }
        onActivate()
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
