import AppKit

/// The shared labeled button across the chrome (the text-button counterpart to `IconButton`):
/// a flat, rounded-6 pill that's theme-tinted, lifts a faint background on hover, and grows with
/// its title. Used by the Add-Workspace form and the confirm toasts.
///
/// Variants:
/// - `primary` — accent text; dims when disabled (a form's Add).
/// - `secondary` — muted ghost, transparent at rest (Cancel / a toast's cancel).
/// - `muted` — muted text on a subtle fill (a form's Add-variable).
/// - `destructive` — destructive-tinted, subtle fill (a toast's confirm).
/// - `segment` — an accent toggle that fills when `isOn` (a form's focus selector).
final class AppButton: NSButton {
    enum Variant { case primary, secondary, muted, destructive, segment }

    var onTap: () -> Void
    /// Segment selection state — fills with the accent when true. Ignored by other variants.
    var isOn = false { didSet { restyle() } }

    /// Opt into the form keyboard flow: the button becomes a focus stop that shows an accent
    /// ring, moves focus on Up/Down (via the callbacks), and activates on Return/Space. Off by
    /// default so toast buttons stay click-and-key-equivalent only.
    var isKeyboardFocusable = false
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onArrowRight: (() -> Void)?
    /// Tab / Shift-Tab, when the host wants them to differ from Down / Up — the Settings sections do
    /// (Tab wraps at the last stop; Shift-Tab retreats, exiting to the nav only from the first).
    /// Unset elsewhere, so the forms keep Tab as a plain advance/retreat through their stops.
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    /// Draw the accent focus outline without being first responder — used by `SegmentedControl`
    /// to outline its selected segment while the control (not the segment) holds focus.
    var showsFocusOutline = false { didSet { restyle() } }

    private let variant: Variant
    private let symbolName: String?
    private var labelText: String
    private var isHovered = false { didSet { restyle() } }
    private var isFocusedStop = false { didSet { restyle() } }
    private var trackingAreaRef: NSTrackingArea?

    /// Breathing room on each side of the title so the pill grows with its label instead of the
    /// text touching the rounded edges (a borderless NSButton's intrinsic width is otherwise tight).
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

    /// Change the button's label after init (e.g. "Set" → "Change" as a keybind row's recorded
    /// state changes) and restyle so the new title picks up the current variant/state colors.
    func setTitle(_ title: String) {
        labelText = title
        restyle()
    }

    /// Re-apply the live chrome colors after a config change — no relaunch. `restyle()` already
    /// reads `Theme.current` fresh on every call; it just needs re-triggering.
    func reapplyTheme() { restyle() }

    // MARK: keyboard focus (form flow)

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

    /// We draw our own accent ring via the layer border, so suppress the system focus ring.
    override func drawFocusRingMask() {}

    override func keyDown(with event: NSEvent) {
        guard isKeyboardFocusable else { return super.keyDown(with: event) }
        switch KeyboardFocus.key(for: event) {
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .left where onArrowLeft != nil: onArrowLeft?()
        case .right where onArrowRight != nil: onArrowRight?()
        // Tab / Shift-Tab advance and retreat like Down / Up unless the host wires them apart — and
        // stay consumed here either way, so focus can't jump the key-view loop out of the card's 2D
        // model.
        case .tab(let shift):
            if shift {
                (onBacktab ?? onArrowUp)?()
            } else {
                (onTab ?? onArrowDown)?()
            }
        case .activate: fire()  // return / enter / space → activate
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
            textColor = isEnabled ? chrome.accent.nsColor : chrome.ink(alpha: 0.25)
            background = isHovered && isEnabled ? chrome.ink(alpha: 0.16) : chrome.ink(alpha: 0.09)
        case .secondary:
            textColor = chrome.muted.nsColor
            background = isHovered ? chrome.ink(alpha: 0.09) : .clear
        case .muted:
            textColor = chrome.muted.nsColor
            background = isHovered ? chrome.ink(alpha: 0.14) : chrome.ink(alpha: 0.09)
        case .destructive:
            textColor = chrome.destructive.nsColor
            background = isHovered ? chrome.ink(alpha: 0.12) : chrome.ink(alpha: 0.07)
        case .segment:
            textColor = isOn ? chrome.accent.nsColor : chrome.muted.nsColor
            background =
                isOn
                ? chrome.accent.nsColor.withAlphaComponent(0.16)
                : (isHovered ? chrome.ink(alpha: 0.09) : chrome.ink(alpha: 0.05))
        }
        layer?.backgroundColor = background.cgColor
        // Focus (as a stop, or an outlined segment) reads as an accent outline, not a fill.
        let outlined = isFocusedStop || showsFocusOutline
        layer?.borderWidth = outlined ? 1.5 : 0
        layer?.borderColor = outlined ? chrome.accent.nsColor.cgColor : nil
        if symbolName != nil {
            contentTintColor = textColor  // tint the SF Symbol like the variant's text would be
        } else {
            attributedTitle = NSAttributedString(
                string: labelText,
                attributes: [
                    .foregroundColor: textColor,
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                ])
        }
    }

    @objc private func fire() { onTap() }
}
