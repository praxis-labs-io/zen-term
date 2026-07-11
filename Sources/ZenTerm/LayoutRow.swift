import AppKit

/// One Layout & Motion row: a caption, an editing control (Slider / FieldBox / SegmentedControl),
/// a reset-to-default icon shown only when overridden, and an inline validation message. The
/// control is supplied by the section (which owns its keyboard wiring); the row hosts it and owns
/// the reset stop. Reset is reached with Tab from the control and Left from the reset.
final class LayoutRow: NSView {
    let resetButton = AppButton(variant: .muted, symbol: "arrow.uturn.backward")
    var onReset: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onEsc: (() -> Void)?
    /// Called when Left/⇧Tab leaves the reset icon — the section returns focus to this row's control.
    var onFocusControl: (() -> Void)?

    private let messageLabel = NSTextField(labelWithString: "")

    init(caption: String, control: NSView, note: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.current.chrome.foreground.nsColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let captionStack: NSView
        if let note {
            let noteLabel = NSTextField(labelWithString: note)
            noteLabel.font = .systemFont(ofSize: 10)
            noteLabel.textColor = Theme.current.chrome.ink(alpha: 0.4)
            let stack = NSStackView(views: [label, noteLabel])
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.alignment = .firstBaseline
            captionStack = stack
        } else {
            captionStack = label
        }

        resetButton.isKeyboardFocusable = true
        resetButton.setAccessibilityLabel("Reset to default")
        resetButton.onArrowUp = { [weak self] in self?.onArrowUp?() }
        resetButton.onArrowDown = { [weak self] in self?.onArrowDown?() }
        resetButton.onArrowLeft = { [weak self] in self?.onFocusControl?() }
        resetButton.onEsc = { [weak self] in self?.onEsc?() }
        resetButton.onTap = { [weak self] in self?.onReset?() }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [captionStack, spacer, control, resetButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        messageLabel.font = .systemFont(ofSize: 11, weight: .medium)
        messageLabel.textColor = Theme.current.chrome.destructive.nsColor
        messageLabel.isHidden = true

        let stack = NSStackView(views: [controls, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            control.widthAnchor.constraint(equalToConstant: 180),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(isOverridden: Bool) { resetButton.isHidden = !isOverridden }
    /// Focus the reset icon if it's shown (row overridden); returns whether it moved focus, so the
    /// caller can advance elsewhere when there's no reset to reach.
    @discardableResult
    func focusReset() -> Bool {
        guard !resetButton.isHidden else { return false }
        window?.makeFirstResponder(resetButton)
        return true
    }
    func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = (text == nil)
    }
}
