import AppKit

final class SSHHostRow: SettingsFocusRow {
    let host: String
    let layout: LayoutRow
    var isEditable: Bool {
        didSet {
            guard isEditable != oldValue else { return }
            setAccessibilityElement(isEditable)
            window?.invalidateCursorRects(for: self)
        }
    }

    init(host: String, layout: LayoutRow, isEditable: Bool) {
        self.host = host
        self.layout = layout
        self.isEditable = isEditable
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityElement(isEditable)
        pin(layout)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func reapplyTheme() {
        layout.reapplyTheme()
        super.reapplyTheme()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEditable else { return false }
        onActivate?()
        return true
    }

    override var acceptsFirstResponder: Bool { isEditable }
}
