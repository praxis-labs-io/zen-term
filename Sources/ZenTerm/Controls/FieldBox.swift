import AppKit

final class FieldBox: NSView, NSTextFieldDelegate {
    let field = ClickField()
    var onChange: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onArrowRight: (() -> Void)?
    var onEnter: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onEndEditing: (() -> Void)?
    var onSubmit: (() -> Void)?
    // Handled here because `performKeyEquivalent` does not run for a bare Esc while a popover host holds focus.
    var onEscape: (() -> Bool)?

    private static var restFill: NSColor { Theme.current.chrome.fill(.rest) }
    private static var focusFill: NSColor { Theme.current.chrome.selectionFill }

    var text: String { field.stringValue }
    func setText(_ value: String) { field.stringValue = value }

    // Retained because `placeholderString` reads nil once `placeholderAttributedString` is set.
    let placeholder: String

    init(placeholder: String) {
        self.placeholder = placeholder
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Self.restFill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.current.chrome.fill(alpha: ChromeTheme.border).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        applyPlaceholder()
        field.textColor = Theme.current.chrome.foreground.nsColor
        field.delegate = self
        field.onGainedFocus = { [weak self] in self?.setFocused(true) }
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func controlTextDidChange(_ obj: Notification) { onChange?() }
    // Focus clears here because resign never reaches the field: its field editor is the real responder.
    func controlTextDidEndEditing(_ obj: Notification) {
        setFocused(false)
        onEndEditing?()
    }

    func reapplyTheme() {
        setFocused(field.currentEditor() != nil)
        field.textColor = Theme.current.chrome.foreground.nsColor
        field.applyThemedCaret()
        applyPlaceholder()
    }

    // The system placeholder tint follows `effectiveAppearance`, not `Theme.current`.
    private func applyPlaceholder() {
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: Theme.current.chrome.ink(.muted),
                .font: field.font ?? .systemFont(ofSize: 13),
            ]
        )
    }

    private func setFocused(_ focused: Bool) {
        let chrome = Theme.current.chrome
        layer?.backgroundColor = (focused ? Self.focusFill : Self.restFill).cgColor
        layer?.borderColor = (focused ? chrome.accent.nsColor : chrome.fill(alpha: ChromeTheme.border)).cgColor
        layer?.borderWidth = focused ? 1.5 : 1
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            onArrowUp?()
        case #selector(NSResponder.moveDown(_:)):
            onArrowDown?()
        case #selector(NSResponder.moveLeft(_:)):
            guard let onArrowLeft, cursorAtStart(textView) else { return false }
            onArrowLeft()
        case #selector(NSResponder.moveRight(_:)):
            guard let onArrowRight, cursorAtEnd(textView) else { return false }
            onArrowRight()
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                onSubmit?()
            } else {
                (onEnter ?? onArrowDown)?()
            }
        case #selector(NSResponder.cancelOperation(_:)):
            guard let onEscape, onEscape() else { return false }
        case #selector(NSResponder.insertTab(_:)):
            guard let onTab else { return false }
            onTab()
        case #selector(NSResponder.insertBacktab(_:)):
            guard let onBacktab else { return false }
            onBacktab()
        default:
            return false
        }
        return true
    }

    private func cursorAtStart(_ textView: NSTextView) -> Bool {
        let range = textView.selectedRange()
        return range.location == 0 && range.length == 0
    }

    private func cursorAtEnd(_ textView: NSTextView) -> Bool {
        let range = textView.selectedRange()
        return range.location == (textView.string as NSString).length && range.length == 0
    }

    // Editing notifications don't fire reliably under keyboard navigation, so focus comes from responder transitions.
    final class ClickField: NSTextField {
        var onGainedFocus: (() -> Void)?

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok {
                applyThemedCaret()
                onGainedFocus?()
            }
            return ok
        }
    }
}
