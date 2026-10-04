import AppKit

final class SSHHostRow: NSView {
    let host: String
    let layout: LayoutRow
    var isEditable: Bool {
        didSet {
            guard isEditable != oldValue else { return }
            setAccessibilityElement(isEditable)
            window?.invalidateCursorRects(for: self)
        }
    }
    var onActivate: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowRight: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onExitToNav: (() -> Void)?

    private var isFocused = false { didSet { restyle() } }

    init(host: String, layout: LayoutRow, isEditable: Bool) {
        self.host = host
        self.layout = layout
        self.isEditable = isEditable
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        setAccessibilityRole(.button)
        setAccessibilityElement(isEditable)

        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            layout.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        layout.reapplyTheme()
        restyle()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEditable else { return false }
        onActivate?()
        return true
    }

    override var acceptsFirstResponder: Bool { isEditable }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }
    override func drawFocusRingMask() {}

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .activate: onActivate?()
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .right: onArrowRight?()
        case .left: onExitToNav?()
        case .tab(let shift) where onTab != nil || onBacktab != nil:
            shift ? onBacktab?() : onTab?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditable else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        onActivate?()
    }

    override func resetCursorRects() {
        if isEditable { addCursorRect(bounds, cursor: .pointingHand) }
    }

    private func restyle() {
        let chrome = Theme.current.chrome
        layer?.backgroundColor = isFocused ? chrome.fill(.active).cgColor : nil
        layer?.borderWidth = isFocused ? 1.5 : 0
        layer?.borderColor = isFocused ? chrome.accent.nsColor.cgColor : nil
    }
}
