import AppKit

final class FieldBox: NSView, NSTextFieldDelegate {
    let field: NSTextField
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
    var onEscape: (() -> Void)?

    var text: String { editor?.string ?? field.stringValue }
    func setText(_ value: String) {
        field.stringValue = value
        editor?.string = value
    }

    // Retained because `placeholderString` reads nil once `placeholderAttributedString` is set.
    private(set) var placeholder: String

    func setPlaceholder(_ value: String) {
        placeholder = value
        applyPlaceholder()
    }

    init(placeholder: String, hidesText: Bool = false) {
        self.placeholder = placeholder
        let reporting: NSTextField & FocusReporting = hidesText ? HiddenClickField() : ClickField()
        field = reporting
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.control
        setFocused(false)
        translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = ChromeType.font(.body)
        field.makeSingleLine()
        applyPlaceholder()
        field.textColor = Theme.current.chrome.ink(.normal)
        field.delegate = self
        reporting.onGainedFocus = { [weak self] in self?.setFocused(true) }
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: ChromeMetrics.Height.control),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.Spacing.controlInset),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChromeMetrics.Spacing.controlInset),
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
        setFocused(editor != nil)
        field.textColor = Theme.current.chrome.ink(.normal)
        field.applyThemedEditor()
        applyPlaceholder()
    }

    // A secure field's editor is first responder without showing up as its `currentEditor()`.
    private var editor: NSText? {
        guard let editor = field.window?.firstResponder as? NSText, editor.delegate === field else { return nil }
        return editor
    }

    // The system placeholder tint follows `effectiveAppearance`, not `Theme.current`.
    private func applyPlaceholder() {
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: Theme.current.chrome.ink(.muted),
                .font: field.font ?? ChromeType.font(.body),
            ]
        )
    }

    private func setFocused(_ focused: Bool) {
        FieldChrome.apply(to: self, isFocused: focused)
    }

    #if DEBUG
        func forceFocusForGallery() { setFocused(true) }
    #endif

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
        case #selector(NSResponder.insertTab(_:)):
            guard let onTab else { return false }
            onTab()
        case #selector(NSResponder.insertBacktab(_:)):
            guard let onBacktab else { return false }
            onBacktab()
        case #selector(NSResponder.cancelOperation(_:)):
            guard let onEscape else { return false }
            onEscape()
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
    private protocol FocusReporting: AnyObject {
        var onGainedFocus: (() -> Void)? { get set }
    }

    private final class ClickField: NSTextField, FocusReporting {
        var onGainedFocus: (() -> Void)?

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onGainedFocus?() }
            return ok
        }
    }

    private final class HiddenClickField: NSSecureTextField, FocusReporting {
        var onGainedFocus: (() -> Void)?

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onGainedFocus?() }
            return ok
        }
    }
}
