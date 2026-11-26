import AppKit

class SidebarJumpRow: ListRow {
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    var onFocusChanged: (() -> Void)?

    init(_ content: Content = Content(title: ""), tooltip: String, onActivate: @escaping () -> Void) {
        super.init(content, onChoose: onActivate)
        self.tooltip = TooltipHost(label: tooltip)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var fillForTesting: CGColor? { layer?.backgroundColor }

    override func focusDidChange() {
        super.focusDidChange()
        onFocusChanged?()
    }

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .activate where KeyboardFocus.isReturn(event): (onReturn ?? onChoose)()
        case .escape where onEscape != nil && KeyboardFocus.isUnmodified(event): onEscape?()
        default: super.keyDown(with: event)
        }
    }
}
