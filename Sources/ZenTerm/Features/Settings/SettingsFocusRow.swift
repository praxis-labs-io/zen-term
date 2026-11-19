import AppKit

class SettingsFocusRow: ListRow {
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowRight: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onExitToNav: (() -> Void)?

    init(_ content: Content) {
        super.init(content) {}
        focusesOnClick = true
        setAccessibilityRole(.button)
        heightAnchor.constraint(greaterThanOrEqualToConstant: ChromeMetrics.Height.control).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
        case .activate: onChoose()
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .right where onArrowRight != nil: onArrowRight?()
        case .left: onExitToNav?()
        case .tab(let shift) where onTab != nil || onBacktab != nil:
            shift ? onBacktab?() : onTab?()
        default: super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
