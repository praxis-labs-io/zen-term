import AppKit

final class KeybindChip: NSView {
    var onActivate: (() -> Void)?
    var onRemove: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onExitToNav: (() -> Void)?

    static let width: CGFloat = 110

    private let host = NSView()
    private var isFocused = false { didSet { restyle() } }
    private(set) var isCapturing = false { didSet { restyle() } }
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

    func render(shortcut: String) {
        host.subviews.forEach { $0.removeFromSuperview() }
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

    func setCapturing(_ capturing: Bool) { isCapturing = capturing }

    func reapplyTheme() { restyle() }

    var renderedShortcutForTesting: String? {
        (host.subviews.first as? KeycapView)?.shortcut
    }

    private func placeholder(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.current.chrome.ink(.muted)
        return label
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }
    override func drawFocusRingMask() {}

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .activate: onActivate?()
        case .delete: onRemove?()
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .left: onExitToNav?()
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
            fill = chrome.fill(.active)
        } else if isFocused || isHovered {
            fill = chrome.fill(.hover)
        } else {
            fill = chrome.fill(.rest)
        }
        layer?.backgroundColor = fill.cgColor
        let outlined = isFocused || isCapturing
        layer?.borderWidth = outlined ? 1.5 : 0
        layer?.borderColor = outlined ? chrome.accent.nsColor.cgColor : nil
    }
}
