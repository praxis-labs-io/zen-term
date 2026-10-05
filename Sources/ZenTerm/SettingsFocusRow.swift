import AppKit

class SettingsFocusRow: NSView {
    var onActivate: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowRight: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onExitToNav: (() -> Void)?

    private var isFocused = false { didSet { restyle() } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func pin(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    func reapplyTheme() { restyle() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }
    override func drawFocusRingMask() {}

    // KeyboardFocus.key(for:) decodes the keyCode alone, so ⌥ is checked here.
    override func keyDown(with event: NSEvent) {
        let key = KeyboardFocus.key(for: event)
        if KeyboardFocus.isOptionOnly(event) {
            switch key {
            case .up where onMoveUp != nil: onMoveUp?(); return
            case .down where onMoveDown != nil: onMoveDown?(); return
            default: break
            }
        }
        switch key {
        case .activate: onActivate?()
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .right where onArrowRight != nil: onArrowRight?()
        case .left: onExitToNav?()
        case .tab(let shift) where onTab != nil || onBacktab != nil:
            shift ? onBacktab?() : onTab?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard acceptsFirstResponder else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        onActivate?()
    }

    override func resetCursorRects() {
        if acceptsFirstResponder { addCursorRect(bounds, cursor: .pointingHand) }
    }

    private func restyle() {
        let chrome = Theme.current.chrome
        layer?.backgroundColor = isFocused ? chrome.fill(.active).cgColor : nil
        layer?.borderWidth = isFocused ? 1.5 : 0
        layer?.borderColor = isFocused ? chrome.accent.nsColor.cgColor : nil
    }
}
