import AppKit

/// A keybind's chord shown as a focusable, fixed-width target — the control for changing it. All
/// chips share one width so the shortcuts read as a uniform column; the chord sits centered inside.
/// At rest it looks like a plain `KeycapView`; focused it gains an accent ring; capturing it takes an
/// accent fill (the section shows a branded popover). Return / Space / click begins capture,
/// Backspace leaves the action with no shortcut at all, Up/Down move rows, Left exits to nav; Esc
/// closes the card (owned by the card root — see `ModalEscape`). Reset-to-default is a button in
/// the capture popover.
final class KeybindChip: NSView {
    var onActivate: (() -> Void)?  // Return / Space / click → begin capture
    var onRemove: (() -> Void)?  // Backspace → no shortcut at all
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onExitToNav: (() -> Void)?

    /// One width for every shortcut input, so they line up as a column rather than sizing to content.
    static let width: CGFloat = 110

    private let host = NSView()
    private var isFocused = false { didSet { restyle() } }
    private(set) var isCapturing = false { didSet { restyle() } }
    /// A mouse over the chip. Without it the only sign this is a target was the pointing-hand
    /// cursor, which is a lot to ask of a row in a list of forty.
    private var isHovered = false { didSet { restyle() } }
    private var trackingAreaRef: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: 32),
            host.centerXAnchor.constraint(equalTo: centerXAnchor),
            host.centerYAnchor.constraint(equalTo: centerYAnchor),
            host.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            host.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Show the current chord centered (or a muted placeholder when unbound).
    func render(shortcut: String) {
        host.subviews.forEach { $0.removeFromSuperview() }
        // Chromeless keycap — the chip's own full-width fill is the background, not an inner box.
        let content: NSView =
            shortcut.isEmpty ? placeholder("Not set") : KeycapView(shortcut: shortcut, showsBackground: false)
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    /// The "listening" look while the section captures the next chord — the chord stays visible under
    /// an accent fill (the popover carries the instructions).
    func setCapturing(_ capturing: Bool) { isCapturing = capturing }

    /// Re-apply the live chrome colors after a config change — no relaunch. `restyle()` already
    /// reads `Theme.current` fresh on every call; it just needs re-triggering (the box's fill and
    /// border, unlike the inner glyph, aren't rebuilt by `render(shortcut:)`).
    func reapplyTheme() { restyle() }

    /// Test hook: the chord the chip is currently drawing, or nil when it's showing the unbound
    /// placeholder. Reads the rendered subview rather than a stored string, so a test can't pass
    /// while the chip actually displays something else.
    var renderedShortcutForTesting: String? {
        (host.subviews.first as? KeycapView)?.shortcut
    }

    private func placeholder(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.current.chrome.ink(.muted)
        return label
    }

    // MARK: focus + keyboard

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }
    override func drawFocusRingMask() {}

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .activate: onActivate?()  // return / enter / space → begin capture
        // Delete means delete. It used to restore the default, which reads as doing nothing on the
        // rows most likely to be pressed: an action whose default is the chord something else
        // already holds gets it back and loses it again on the reload. Reset lives on a button in
        // the capture popover now.
        case .delete: onRemove?()
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .left: onExitToNav?()  // left → nav
        case .tab(let shift) where onTab != nil || onBacktab != nil:
            shift ? onBacktab?() : onTab?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onActivate?()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private func restyle() {
        let chrome = Theme.current.chrome
        let fill: NSColor
        if isCapturing {
            fill = chrome.accent.nsColor.withAlphaComponent(0.14)
        } else if isFocused || isHovered {
            // Hover and focus share a fill; the accent ring below is what still tells them apart.
            fill = chrome.ink(alpha: 0.10)
        } else {
            fill = chrome.ink(alpha: 0.06)
        }
        layer?.backgroundColor = fill.cgColor
        let outlined = isFocused || isCapturing
        layer?.borderWidth = outlined ? 1.5 : 0
        layer?.borderColor = outlined ? chrome.accent.nsColor.cgColor : nil
    }
}
