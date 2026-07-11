import AppKit

/// A keybind's chord shown as a focusable chip — the control for changing it. At rest it looks like
/// a plain `KeycapView`; focused it gains an accent ring. Return / Space / click begins capture (the
/// section shows a hint bubble and diverts the next chord); Backspace reverts to the default. Up/Down
/// move between rows, Left exits to the nav, Esc closes the card.
final class KeybindChip: NSView {
    var onActivate: (() -> Void)?  // Return / Space / click → begin capture
    var onReset: (() -> Void)?  // Backspace → revert to default
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onExitToNav: (() -> Void)?
    var onEsc: (() -> Void)?

    private let host = NSView()
    private var isFocused = false { didSet { restyle() } }
    private(set) var isCapturing = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            host.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            host.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Show the current chord (or a muted placeholder when unbound); clears the capturing state.
    func render(shortcut: String) {
        isCapturing = false
        setContent(shortcut.isEmpty ? placeholder("Not set") : KeycapView(shortcut: shortcut))
        restyle()
    }

    /// Switch to the "listening" look while the section captures the next chord.
    func setCapturing(_ capturing: Bool) {
        isCapturing = capturing
        if capturing { setContent(placeholder("Press keys…")) }
        restyle()
    }

    private func setContent(_ view: NSView) {
        host.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            view.topAnchor.constraint(greaterThanOrEqualTo: host.topAnchor),
        ])
    }

    private func placeholder(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.current.chrome.ink(alpha: isCapturing ? 0.7 : 0.4)
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
