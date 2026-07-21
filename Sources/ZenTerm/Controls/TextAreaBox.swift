import AppKit

/// A rounded, chrome-styled box wrapping an editable multiline `NSTextView` in a scroll view — the
/// multiline sibling of `FieldBox`. On focus its fill lifts to the palettes' muted accent and its
/// edge outlines with the accent. Return inserts a newline; ⌘Return submits; Tab / Shift-Tab leave;
/// Up from the first line and Down from the last line leave (mid-text they move between lines), so it
/// slots into a form's keyboard focus ring. Esc belongs to the card root (see `ModalEscape`), not the
/// text view. A shared form-control primitive.
final class TextAreaBox: NSView, NSTextViewDelegate {
    let textView = FocusReportingTextView()
    var onChange: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    /// ⌘Return anywhere in the text — submit the whole form.
    var onSubmit: (() -> Void)?

    /// Retained so callers (tests included) can identify a box by its placeholder, and so a theme
    /// swap can recolor the placeholder label in place.
    let placeholder: String
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()

    private static var restFill: NSColor { Theme.current.chrome.ink(alpha: 0.06) }
    /// The same muted accent fill the ⌘P/⌘⇧P palettes use for the selected row.
    private static var focusFill: NSColor { PaletteOverlay.selectionBackground }

    var text: String { textView.string }
    func setText(_ value: String) {
        textView.string = value
        updatePlaceholderVisibility()
    }

    init(placeholder: String, minHeight: CGFloat = 96) {
        self.placeholder = placeholder
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Self.restFill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.current.chrome.ink(alpha: 0.10).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        // An NSTextView in a scroll view is sized by AppKit's autoresizing, not autolayout — the
        // classic configuration (the scroll view itself is autolayout inside this box).
        textView.isRichText = false
        textView.isEditable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = Theme.current.chrome.foreground.nsColor
        textView.insertionPointColor = Theme.current.chrome.foreground.nsColor
        textView.textContainerInset = NSSize(width: 3, height: 5)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        textView.onFocusChange = { [weak self] focused in self?.setFocused(focused) }

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = SlimScroller()
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        // NSTextView has no built-in placeholder, so a muted label sits at the top-left and hides
        // once there's text (like FieldBox's attributed placeholder, kept readable on light themes).
        placeholderLabel.font = .systemFont(ofSize: 13)
        placeholderLabel.textColor = Theme.current.chrome.ink(alpha: 0.4)
        placeholderLabel.stringValue = placeholder
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        placeholderLabel.isBordered = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        updatePlaceholderVisibility()
        onChange?()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            guard NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return false }
            onSubmit?()
        case #selector(NSResponder.moveUp(_:)):
            guard let onArrowUp, caretIsOnFirstLine(textView) else { return false }  // else move a line up
            onArrowUp()
        case #selector(NSResponder.moveDown(_:)):
            guard let onArrowDown, caretIsOnLastLine(textView) else { return false }
            onArrowDown()
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

    // MARK: focus + theme

    /// Focus lifts the fill to the palettes' muted accent AND outlines the box with the accent —
    /// matching `FieldBox` so every input in a form reads its focus the same way.
    private func setFocused(_ focused: Bool) {
        let chrome = Theme.current.chrome
        layer?.backgroundColor = (focused ? Self.focusFill : Self.restFill).cgColor
        layer?.borderColor = (focused ? chrome.accent.nsColor : chrome.ink(alpha: 0.10)).cgColor
        layer?.borderWidth = focused ? 1.5 : 1
    }

    func reapplyTheme() {
        setFocused(window?.firstResponder === textView)
        textView.textColor = Theme.current.chrome.foreground.nsColor
        textView.insertionPointColor = Theme.current.chrome.foreground.nsColor
        placeholderLabel.textColor = Theme.current.chrome.ink(alpha: 0.4)
    }

    private func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !textView.string.isEmpty
    }

    /// The caret is on the first logical line when no newline precedes it; on the last when none
    /// follows. Logical (not soft-wrapped) lines, so this stays deterministic and layout-free: Up
    /// from the top line and Down from the bottom line leave the field, mid-text they move a line.
    private func caretIsOnFirstLine(_ textView: NSTextView) -> Bool {
        let string = textView.string as NSString
        let caret = min(textView.selectedRange().location, string.length)
        return !string.substring(to: caret).contains("\n")
    }

    private func caretIsOnLastLine(_ textView: NSTextView) -> Bool {
        let string = textView.string as NSString
        let caret = min(textView.selectedRange().location, string.length)
        return !string.substring(from: caret).contains("\n")
    }
}

/// An `NSTextView` that reports its first-responder transitions, so its `TextAreaBox` can show the
/// focus border reliably (the delegate's editing notifications don't fire consistently under
/// keyboard navigation, the same reason `FieldBox.ClickField` exists).
final class FocusReportingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let gained = super.becomeFirstResponder()
        if gained { onFocusChange?(true) }
        return gained
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}
