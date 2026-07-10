import AppKit

/// One Keybinds row: the action label, its current chord as a `KeycapView`, a record button, and
/// a reset-to-default button shown only when overridden. The record button is the row's single
/// vertical focus stop; tapping it asks the section to begin capture (through the interceptor).
final class KeybindRow: NSView {
    let action: KeyInterceptor.ReservedChord
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onRecordTapped: (() -> Void)?
    var onReset: (() -> Void)?

    let recordButton = AppButton(title: "Set", variant: .secondary)
    private let resetButton = AppButton(title: "⤺", variant: .muted)
    private let keycapHost = NSView()
    private let messageLabel = NSTextField(labelWithString: "")
    private var hasBinding = false
    private var isCapturing = false

    init(action: KeyInterceptor.ReservedChord, title: String) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.current.chrome.foreground.nsColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        keycapHost.translatesAutoresizingMaskIntoConstraints = false

        recordButton.isKeyboardFocusable = true
        recordButton.onArrowUp = { [weak self] in self?.onArrowUp?() }
        recordButton.onArrowDown = { [weak self] in self?.onArrowDown?() }
        recordButton.onArrowLeft = { [weak self] in self?.onArrowLeft?() }
        recordButton.onTap = { [weak self] in self?.onRecordTapped?() }

        resetButton.onTap = { [weak self] in self?.onReset?() }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [label, spacer, keycapHost, recordButton, resetButton])
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
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Reflect capturing state on the record button label ("Press keys…" while recording).
    func setCapturing(_ capturing: Bool) {
        isCapturing = capturing
        recordButton.setTitle(recordLabel)
    }

    /// Refresh the keycap, the record button label, and whether the reset control shows.
    func render(currentShortcut: String, isOverridden: Bool) {
        hasBinding = !currentShortcut.isEmpty
        keycapHost.subviews.forEach { $0.removeFromSuperview() }
        if hasBinding {
            let cap = KeycapView(shortcut: currentShortcut)
            cap.translatesAutoresizingMaskIntoConstraints = false
            keycapHost.addSubview(cap)
            NSLayoutConstraint.activate([
                cap.leadingAnchor.constraint(equalTo: keycapHost.leadingAnchor),
                cap.trailingAnchor.constraint(equalTo: keycapHost.trailingAnchor),
                cap.topAnchor.constraint(equalTo: keycapHost.topAnchor),
                cap.bottomAnchor.constraint(equalTo: keycapHost.bottomAnchor),
            ])
        }
        recordButton.setTitle(recordLabel)
        resetButton.isHidden = !isOverridden
    }

    func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = (text == nil)
    }

    private var recordLabel: String {
        if isCapturing { return "Press keys…" }
        return hasBinding ? "Change" : "Set"
    }
}
