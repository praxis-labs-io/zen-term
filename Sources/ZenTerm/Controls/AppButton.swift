import AppKit

final class AppButton: NSButton {
    enum Variant { case primary, secondary, muted, destructive, segment, link }

    enum Size {
        case standard
        case large

        var height: CGFloat {
            switch self {
            case .standard: return ChromeMetrics.Height.control
            case .large: return ChromeMetrics.Height.control
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .standard: return ChromeMetrics.Spacing.s8
            case .large: return ChromeMetrics.Spacing.s12
            }
        }

        var role: ChromeType.Role {
            switch self {
            case .standard: return .small
            case .large: return .body
            }
        }

        var keycapGap: CGFloat {
            switch self {
            case .standard: return ChromeMetrics.Spacing.s6
            case .large: return ChromeMetrics.Spacing.s8
            }
        }
    }

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
    private let size: Size
    private let keycap: KeycapView?
    private let symbolName: String?
    private var labelText: String
    private var isHovered = false { didSet { restyle() } }
    private var isFocusedStop = false { didSet { restyle() } }
    private var trackingAreaRef: NSTrackingArea?

    override var isEnabled: Bool {
        didSet {
            if isEnabled != oldValue, let keycap { keycap.style = Self.keycapStyle(for: variant, isEnabled: isEnabled) }
            restyle()
        }
    }

    override var intrinsicContentSize: NSSize {
        var fitted = super.intrinsicContentSize
        fitted.width += size.horizontalPadding * 2 + keycapReserve
        fitted.height = size.height
        return fitted
    }

    private var keycapReserve: CGFloat {
        guard let keycap else { return 0 }
        return size.keycapGap + keycap.intrinsicContentSize.width
    }

    init(
        title: String = "", variant: Variant, size: Size = .standard, symbol: String? = nil,
        shortcut: String? = nil, keyEquivalent: String = "", keyEquivalentModifierMask: NSEvent.ModifierFlags = [],
        onTap: @escaping () -> Void = {}
    ) {
        self.onTap = onTap
        self.variant = variant
        self.size = size
        self.symbolName = symbol
        self.labelText = title
        self.keycap = shortcut.map { KeycapView(shortcut: $0, style: Self.keycapStyle(for: variant, isEnabled: true)) }
        super.init(frame: .zero)
        let cell = AppButtonCell()
        cell.trailingReserve = keycapReserve
        self.cell = cell
        if let keycap {
            addSubview(keycap)
            NSLayoutConstraint.activate([
                keycap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -size.horizontalPadding),
                keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.control
        setButtonType(.momentaryChange)
        cell.imageDimsWhenDisabled = false
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

    private static func keycapStyle(for variant: Variant, isEnabled: Bool) -> KeycapView.Style {
        guard variant == .primary else { return .chip }
        return .glyph { isEnabled ? $0.accent.nsColor : $0.ink(.faint) }
    }

    func reapplyTheme() {
        keycap?.reapplyTheme()
        restyle()
    }

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
        let (textColor, background) = isEnabled ? enabledColors(chrome) : disabledColors(chrome)
        layer?.backgroundColor = background.cgColor
        let outlined = isEnabled && (isFocusedStop || showsFocusOutline) && variant != .link
        layer?.borderWidth = ChromeMetrics.Border.width
        layer?.borderColor = outlined ? chrome.accent.nsColor.cgColor : NSColor.clear.cgColor
        if symbolName != nil {
            contentTintColor = textColor
        } else {
            let isLink = variant == .link
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: textColor,
                .font: isLink ? ChromeType.font(.body) : ChromeType.font(size.role, weight: .semibold),
            ]
            if isLink, isEnabled, isFocusedStop { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            attributedTitle = NSAttributedString(string: labelText, attributes: attributes)
        }
    }

    private func enabledColors(_ chrome: ChromeTheme) -> (text: NSColor, background: NSColor) {
        switch variant {
        case .primary:
            return (chrome.accent.nsColor, chrome.fill(isHovered ? .hover : .rest))
        case .secondary:
            return (focusTinted(chrome.ink(.subtle), chrome), isHovered ? chrome.fill(.hover) : .clear)
        case .muted:
            return (focusTinted(chrome.ink(.subtle), chrome), chrome.fill(isHovered ? .hover : .rest))
        case .destructive:
            return (chrome.destructive.nsColor, chrome.fill(isHovered ? .hover : .rest))
        case .segment:
            return (
                isOn ? chrome.accent.nsColor : chrome.ink(.subtle),
                isOn ? chrome.fill(.active) : chrome.fill(isHovered ? .hover : .rest)
            )
        case .link:
            let text = isFocusedStop ? chrome.accent.nsColor : chrome.ink(isHovered ? .normal : .subtle)
            return (text, .clear)
        }
    }

    private func disabledColors(_ chrome: ChromeTheme) -> (text: NSColor, background: NSColor) {
        switch variant {
        case .segment: return (chrome.ink(.faint), chrome.fill(isOn ? .active : .rest))
        case .primary, .muted, .destructive: return (chrome.ink(.faint), chrome.fill(.rest))
        case .secondary, .link: return (chrome.ink(.faint), .clear)
        }
    }

    // `.destructive` opts out: losing the warning tone right before the press costs more than consistency.
    private func focusTinted(_ resting: NSColor, _ chrome: ChromeTheme) -> NSColor {
        isFocusedStop ? chrome.accent.nsColor : resting
    }

    @objc private func fire() { onTap() }

    var keycapForTesting: KeycapView? { keycap }

    #if DEBUG
        func forceFocusForGallery() { isFocusedStop = true }
    #endif
}

// AppKit hands `drawTitle` a disabled title already recolored in the system color, which follows the macOS appearance, not the theme.
private final class AppButtonCell: NSButtonCell {
    var trailingReserve: CGFloat = 0

    override func drawTitle(_ _: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        let title = attributedTitle
        let size = title.size()
        let width = min(size.width, frame.width - trailingReserve)
        let rect = NSRect(
            x: frame.minX + (frame.width - width) / 2 - trailingReserve / 2,
            y: frame.minY + (frame.height - size.height) / 2,
            width: width, height: size.height)
        if width < size.width {
            truncatingTail(title).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        } else {
            title.draw(in: rect)
        }
        return rect
    }

    private func truncatingTail(_ title: NSAttributedString) -> NSAttributedString {
        let truncated = NSMutableAttributedString(attributedString: title)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        truncated.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: truncated.length))
        return truncated
    }
}
