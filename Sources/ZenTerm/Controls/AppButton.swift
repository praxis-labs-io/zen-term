import AppKit

final class AppButton: NSButton {
    enum Variant { case primary, secondary, muted, destructive, segment, link, filled }

    private struct Metrics {
        let height: CGFloat
        let horizontalPadding: CGFloat
        let cornerRadius: CGFloat
        let fontSize: CGFloat
        let keycapGap: CGFloat
    }

    private static let standardMetrics = Metrics(
        height: 26, horizontalPadding: 8, cornerRadius: 6, fontSize: 12, keycapGap: 6)
    private static let filledMetrics = Metrics(
        height: 38, horizontalPadding: 18, cornerRadius: 10, fontSize: 13, keycapGap: 10)

    var onTap: () -> Void
    var isOn = false { didSet { restyle() } }

    var isKeyboardFocusable = false
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onArrowRight: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var showsFocusOutline = false { didSet { restyle() } }

    private let variant: Variant
    private let symbolName: String?
    private var labelText: String
    private var isHovered = false { didSet { restyle() } }
    private var isFocusedStop = false { didSet { restyle() } }
    private var trackingAreaRef: NSTrackingArea?

    private let metrics: Metrics
    private let keycap: KeycapView?

    override var isEnabled: Bool { didSet { restyle() } }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += metrics.horizontalPadding * 2 + keycapReserve
        size.height = metrics.height
        return size
    }

    private var keycapReserve: CGFloat {
        guard let keycap else { return 0 }
        return metrics.keycapGap + keycap.intrinsicContentSize.width
    }

    init(
        title: String = "", variant: Variant, symbol: String? = nil, shortcut: String? = nil,
        keyEquivalent: String = "", keyEquivalentModifierMask: NSEvent.ModifierFlags = [],
        onTap: @escaping () -> Void = {}
    ) {
        self.onTap = onTap
        self.variant = variant
        self.symbolName = symbol
        self.labelText = title
        self.metrics = variant == .filled ? Self.filledMetrics : Self.standardMetrics
        self.keycap = shortcut.map { KeycapView(shortcut: $0, tone: variant == .filled ? .inverse : .plain) }
        super.init(frame: .zero)
        if keycap != nil { cell = KeycapClearingCell() }
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = metrics.cornerRadius
        if let keycap {
            addSubview(keycap)
            NSLayoutConstraint.activate([
                keycap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metrics.horizontalPadding),
                keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            (cell as? KeycapClearingCell)?.trailingReserve = keycapReserve
        }
        setButtonType(.momentaryChange)
        if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            imagePosition = .imageOnly
        }
        target = self
        action = #selector(fire)
        self.keyEquivalent = keyEquivalent
        self.keyEquivalentModifierMask = keyEquivalentModifierMask
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setTitle(_ title: String) {
        labelText = title
        restyle()
    }

    func reapplyTheme() {
        keycap?.reapplyTheme()
        restyle()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override var acceptsFirstResponder: Bool { isKeyboardFocusable && isEnabled }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        isFocusedStop = ok
        return ok
    }

    override func resignFirstResponder() -> Bool {
        isFocusedStop = false
        return super.resignFirstResponder()
    }

    // The accent ring is drawn on the layer border instead.
    override func drawFocusRingMask() {}

    override func keyDown(with event: NSEvent) {
        guard isKeyboardFocusable else { return super.keyDown(with: event) }
        switch KeyboardFocus.key(for: event) {
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .left where onArrowLeft != nil: onArrowLeft?()
        case .right where onArrowRight != nil: onArrowRight?()
        case .tab(let shift):
            if shift {
                (onBacktab ?? onArrowUp)?()
            } else {
                (onTab ?? onArrowDown)?()
            }
        case .activate: fire()
        default: super.keyDown(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    private func restyle() {
        let chrome = Theme.current.chrome
        let textColor: NSColor
        var background: NSColor
        switch variant {
        case .primary:
            textColor = isEnabled ? chrome.accent.nsColor : chrome.ink(.faint)
            background = chrome.fill(isHovered && isEnabled ? .hover : .rest)
        case .secondary:
            textColor = focusTinted(chrome.muted.nsColor, chrome)
            background = isHovered ? chrome.fill(.hover) : .clear
        case .muted:
            textColor = focusTinted(chrome.muted.nsColor, chrome)
            background = chrome.fill(isHovered ? .hover : .rest)
        case .destructive:
            textColor = chrome.destructive.nsColor
            background = chrome.fill(isHovered ? .hover : .rest)
        case .segment:
            textColor = isOn ? chrome.accent.nsColor : chrome.muted.nsColor
            background = isOn ? chrome.fill(.active) : chrome.fill(isHovered ? .hover : .rest)
        case .link:
            textColor =
                isFocusedStop
                ? chrome.accent.nsColor : (isHovered ? chrome.foreground.nsColor : chrome.muted.nsColor)
            background = .clear
        case .filled:
            textColor = isEnabled ? chrome.background.nsColor : chrome.ink(.faint)
            let solid = chrome.accent.nsColor
            let lifted = ChromeTheme.surface(tint: chrome.fill(.hover), over: solid)
            background = isEnabled ? (isHovered ? lifted : solid) : chrome.fill(.rest)
        }
        layer?.backgroundColor = background.cgColor
        let outlined = (isFocusedStop || showsFocusOutline) && variant != .link
        layer?.borderWidth = outlined ? 1.5 : 0
        let ring = variant == .filled ? chrome.foreground : chrome.accent
        layer?.borderColor = outlined ? ring.nsColor.cgColor : nil
        if symbolName != nil {
            contentTintColor = textColor
        } else {
            let isLink = variant == .link
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: textColor,
                .font: NSFont.systemFont(ofSize: isLink ? 13 : metrics.fontSize, weight: isLink ? .regular : .semibold),
            ]
            if isLink, isFocusedStop { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            attributedTitle = NSAttributedString(string: labelText, attributes: attributes)
        }
    }

    // `.destructive` opts out: losing the warning tone right before the press costs more than consistency.
    private func focusTinted(_ resting: NSColor, _ chrome: ChromeTheme) -> NSColor {
        isFocusedStop ? chrome.accent.nsColor : resting
    }

    @objc private func fire() { onTap() }

    var keycapForTesting: KeycapView? { keycap }
}

private final class KeycapClearingCell: NSButtonCell {
    var trailingReserve: CGFloat = 0

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        super.drawTitle(title, withFrame: frame.offsetBy(dx: -trailingReserve / 2, dy: 0), in: controlView)
    }
}
