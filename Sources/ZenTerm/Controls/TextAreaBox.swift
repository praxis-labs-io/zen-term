import AppKit

/// A rounded, chrome-styled box wrapping an editable multiline `NSTextView` in a scroll view — the
/// multiline sibling of `FieldBox`. On focus its fill lifts to the palettes' muted accent and its
/// edge outlines with the accent. Return inserts a newline; ⌘Return submits; Tab / Shift-Tab leave;
/// Up from the start and Down from the end leave (mid-text they move the caret), so it slots into a
/// form's keyboard focus ring. Esc belongs to the card root (see `ModalEscape`), not the text view. A
/// shared form-control primitive.
final class TextAreaBox: NSView, NSTextViewDelegate {
    let textView = FocusReportingTextView()
    var onChange: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    /// ⌘Return anywhere in the text — submit the whole form.
    var onSubmit: (() -> Void)?

    /// Retained so callers (tests included) can identify a box by its placeholder.
    let placeholder: String
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
        // Off by default on a bare `NSTextView`, unlike a field editor, so Edit > Undo would grey out
        // in the one box people write paragraphs in.
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = Theme.current.chrome.foreground.nsColor
        textView.insertionPointColor = Theme.current.chrome.foreground.nsColor
        // Text lands 7pt in from the box on both axes, matching `FieldBox`: its field sits at 9 less
        // the 2pt alignment bleed AppKit gives an `NSTextField`. The container carries the padding and
        // the scroll is only the viewport (2pt in, below), so the two inputs in a form line up. The
        // layout manager's own 5pt line fragment padding goes to zero, or it adds a fourth term nobody
        // sees in a constraint.
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.textContainer?.lineFragmentPadding = 0
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

        // The text view draws the placeholder itself, at the origin its own first glyph takes (kept
        // muted rather than the system placeholder tint, which follows the appearance, not the theme).
        textView.placeholder = placeholder
        textView.placeholderColor = Theme.current.chrome.ink(alpha: 0.4)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
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
            // Leave only from the very start; elsewhere Up moves the caret up a line (return false).
            // Testing the caret position, not the visual line, so a soft-wrapped paragraph (no manual
            // newlines) still navigates line by line instead of exiting on the first Up.
            guard let onArrowUp, textView.selectedRange() == NSRange(location: 0, length: 0) else {
                return false
            }
            onArrowUp()
        case #selector(NSResponder.moveDown(_:)):
            let end = (textView.string as NSString).length
            guard let onArrowDown, textView.selectedRange() == NSRange(location: end, length: 0) else {
                return false
            }
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
        textView.placeholderColor = Theme.current.chrome.ink(alpha: 0.4)
    }

    private func updatePlaceholderVisibility() {
        textView.needsDisplay = true  // the text view decides by its own emptiness as it draws
    }
}

/// An `NSTextView` that reports its first-responder transitions, so its `TextAreaBox` can show the
/// focus border reliably (the delegate's editing notifications don't fire consistently under
/// keyboard navigation, the same reason `FieldBox.ClickField` exists). It also draws its own
/// placeholder.
final class FocusReportingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    /// Drawn while the view is empty. `NSTextView` has no placeholder of its own, and a label laid out
    /// over the view lands on its own insets rather than the text's: the caret sat on the first letter.
    /// Also published to the accessibility tree: the label this replaced was static text VoiceOver
    /// announced, and text painted in `draw` is invisible to it.
    var placeholder = "" {
        didSet {
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }
    var placeholderColor: NSColor = .clear { didSet { needsDisplay = true } }

    /// Where the placeholder draws: the origin the first glyph would take. The container origin covers
    /// `textContainerInset`, and the line fragment padding is the indent the layout manager adds
    /// inside the container on top of it.
    var placeholderOrigin: NSPoint {
        var origin = textContainerOrigin
        origin.x += textContainer?.lineFragmentPadding ?? 0
        return origin
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(
            at: placeholderOrigin,
            withAttributes: [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: placeholderColor])
    }

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
