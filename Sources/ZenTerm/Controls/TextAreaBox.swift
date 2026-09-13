import AppKit

final class TextAreaBox: NSView, NSTextViewDelegate {
    let textView = FocusReportingTextView()
    var onChange: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onSubmit: (() -> Void)?

    let placeholder: String
    private let scroll = NSScrollView()

    private static var restFill: NSColor { Theme.current.chrome.fill(.rest) }
    private static var focusFill: NSColor { Theme.current.chrome.selectionFill }

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
        layer?.borderColor = Theme.current.chrome.fill(alpha: ChromeTheme.border).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = false
        textView.isEditable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = Theme.current.chrome.foreground.nsColor
        textView.insertionPointColor = Theme.current.chrome.foreground.nsColor
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

        textView.placeholder = placeholder
        textView.placeholderColor = Theme.current.chrome.ink(.muted)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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

    private func setFocused(_ focused: Bool) {
        let chrome = Theme.current.chrome
        layer?.backgroundColor = (focused ? Self.focusFill : Self.restFill).cgColor
        layer?.borderColor = (focused ? chrome.accent.nsColor : chrome.fill(alpha: ChromeTheme.border)).cgColor
        layer?.borderWidth = focused ? 1.5 : 1
    }

    func reapplyTheme() {
        setFocused(window?.firstResponder === textView)
        textView.textColor = Theme.current.chrome.foreground.nsColor
        textView.insertionPointColor = Theme.current.chrome.foreground.nsColor
        textView.placeholderColor = Theme.current.chrome.ink(.muted)
    }

    private func updatePlaceholderVisibility() {
        textView.needsDisplay = true
    }
}

final class FocusReportingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    var placeholder = "" {
        didSet {
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }
    var placeholderColor: NSColor = .clear { didSet { needsDisplay = true } }

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
