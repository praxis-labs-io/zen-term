import AppKit

final class AppButton: NSButton {
    enum Variant { case primary, secondary, muted, destructive, segment, link }

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

    private let horizontalPadding: CGFloat = 8
    private let height: CGFloat = 26

    override var isEnabled: Bool { didSet { restyle() } }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += horizontalPadding * 2
        size.height = height
        return size
    }

    init(
        title: String = "", variant: Variant, symbol: String? = nil, keyEquivalent: String = "",
        keyEquivalentModifierMask: NSEvent.ModifierFlags = [], onTap: @escaping () -> Void = {}
    ) {
        self.onTap = onTap
        self.variant = variant
        self.symbolName = symbol
        self.labelText = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
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

    func reapplyTheme() { restyle() }

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
        }
        layer?.backgroundColor = background.cgColor
        let outlined = (isFocusedStop || showsFocusOutline) && variant != .link
        layer?.borderWidth = outlined ? 1.5 : 0
        layer?.borderColor = outlined ? chrome.accent.nsColor.cgColor : nil
        if symbolName != nil {
            contentTintColor = textColor
        } else {
            let isLink = variant == .link
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: textColor,
                .font: NSFont.systemFont(ofSize: isLink ? 13 : 12, weight: isLink ? .regular : .semibold),
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
}
