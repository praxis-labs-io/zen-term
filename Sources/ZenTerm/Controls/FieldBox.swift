import AppKit

/// A rounded input box wrapping a borderless text field. On focus its fill lifts to the palettes'
/// muted accent and its edge outlines with the accent. Forwards edits and keyboard navigation
/// (arrows / Return / Esc / ⌘Return) to the host, and — while empty — a click to `onEmptyClick`
/// (the folder picker). A shared form-control primitive.
final class FieldBox: NSView, NSTextFieldDelegate {
    let field = ClickField()
    var onChange: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    /// Left/Right at the text boundary — used by env rows to step between KEY · value (mid-text
    /// Left/Right still moves the cursor). Unset elsewhere, so those fields keep normal editing.
    var onArrowLeft: (() -> Void)?
    var onArrowRight: (() -> Void)?
    /// Return in this field; defaults to `onArrowDown` (advance) when unset.
    var onEnter: (() -> Void)?
    var onEsc: (() -> Void)?
    /// ⌘Return anywhere in the field — submit the whole form.
    var onSubmit: (() -> Void)?
    var onEmptyClick: (() -> Void)? {
        didSet { field.onEmptyClick = onEmptyClick }
    }

    private static let restFill = Theme.current.chrome.ink(alpha: 0.06)
    /// The same muted accent fill the ⌘P/⌘⇧P palettes use for the selected row.
    private static let focusFill = PaletteOverlay.selectionBackground

    var text: String { field.stringValue }
    func setText(_ value: String) { field.stringValue = value }

    init(placeholder: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Self.restFill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.current.chrome.ink(alpha: 0.10).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
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
    // `becomeFirstResponder` reliably reports focus gained (even under keyboard nav); the matching
    // resign never fires on the field (its field editor is the real responder), so clear focus on
    // `controlTextDidEndEditing`, which does fire when editing moves away.
    func controlTextDidEndEditing(_ obj: Notification) { setFocused(false) }

    /// Focus lifts the fill to the palettes' muted accent AND outlines the box with the accent.
    private func setFocused(_ focused: Bool) {
        let chrome = Theme.current.chrome
        layer?.backgroundColor = (focused ? Self.focusFill : Self.restFill).cgColor
        layer?.borderColor = (focused ? chrome.accent.nsColor : chrome.ink(alpha: 0.10)).cgColor
        layer?.borderWidth = focused ? 1.5 : 1
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            onArrowUp?()
        case #selector(NSResponder.moveDown(_:)):
            onArrowDown?()
        case #selector(NSResponder.moveLeft(_:)):
            guard let onArrowLeft, cursorAtStart(textView) else { return false }  // else move the cursor
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
            onEsc?()
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

    /// An `NSTextField` that, while empty, treats a click as an action (open the folder panel)
    /// rather than beginning to edit — so the folder field needs no separate "Choose" button —
    /// and reports its first-responder transitions so the box can show its focus border reliably
    /// (the editing-notification delegates don't fire consistently under keyboard navigation).
    final class ClickField: NSTextField {
        var onEmptyClick: (() -> Void)?
        var onGainedFocus: (() -> Void)?

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onGainedFocus?() }
            return ok
        }

        override func mouseDown(with event: NSEvent) {
            if stringValue.isEmpty, let onEmptyClick {
                onEmptyClick()
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}
