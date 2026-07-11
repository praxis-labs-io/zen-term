import AppKit

/// A keybind's chord shown as a focusable, fixed-width target — the control for changing it. All
/// chips share one width so the shortcuts read as a uniform column; the chord sits centered inside.
/// At rest it looks like a plain `KeycapView`; focused it gains an accent ring; capturing it takes an
/// accent fill (the section shows a branded popover). Return / Space / click begins capture,
/// Backspace reverts to the default, Up/Down move rows, Left exits to nav, Esc closes the card.
final class KeybindChip: NSView {
    var onActivate: (() -> Void)?  // Return / Space / click → begin capture
    var onReset: (() -> Void)?  // Backspace → revert to default
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onExitToNav: (() -> Void)?
    var onEsc: (() -> Void)?

    /// One width for every shortcut input, so they line up as a column rather than sizing to content.
    static let width: CGFloat = 110

    private let host = NSView()
    private var isFocused = false { didSet { restyle() } }
    private(set) var isCapturing = false { didSet { restyle() } }

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
        let content: NSView = shortcut.isEmpty ? placeholder("Not set") : KeycapView(shortcut: shortcut)
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

    private func placeholder(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.current.chrome.ink(alpha: 0.4)
        return label
    }

    // MARK: focus + keyboard

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }
    override func drawFocusRingMask() {}

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49: onActivate?()  // return / space → begin capture
        case 51 where !isCapturing: onReset?()  // delete → revert to default
        case 126: onArrowUp?()  // up
        case 125: onArrowDown?()  // down
        case 123: onExitToNav?()  // left → nav
        case 53: onEsc?()  // esc (capture-cancel is handled by the capturer, not here)
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onActivate?()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func restyle() {
        let chrome = Theme.current.chrome
        layer?.borderWidth = isFocused ? 1.5 : 0
        layer?.borderColor = isFocused ? chrome.accent.nsColor.cgColor : nil
        layer?.backgroundColor =
            isCapturing ? chrome.accent.nsColor.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
    }
}
