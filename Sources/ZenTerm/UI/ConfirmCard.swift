import AppKit

final class ConfirmCard: ModalShell, ModalOverlay {
    static let width: CGFloat = 420

    private let onConfirm: () -> Void
    private let start: ConfirmPrompt.Start

    private let header: ModalHeader
    private let messageLabel = NSTextField(labelWithString: "")
    private let checklist: ConfirmCardChecklist?
    private let cancelButton: AppButton
    private let confirmButton: AppButton

    convenience init(_ prompt: ConfirmPrompt, onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        let message: String
        let checklist: ConfirmCardChecklist?
        switch prompt.body {
        case .message(let text): (message, checklist) = (text, nil)
        case .checklist(let items): (message, checklist) = ("", ConfirmCardChecklist(items: items))
        }
        self.init(
            title: prompt.title, message: message, checklist: checklist, cancelLabel: prompt.cancelLabel,
            confirmLabel: prompt.confirmLabel, start: prompt.start, onCancel: onCancel, onConfirm: onConfirm)
    }

    private init(
        title: String, message: String, checklist: ConfirmCardChecklist?, cancelLabel: String,
        confirmLabel: String, start: ConfirmPrompt.Start, onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.checklist = checklist
        self.onConfirm = onConfirm
        self.start = start
        header = ModalHeader(title: title)
        cancelButton = AppButton(title: cancelLabel, variant: .secondary)
        confirmButton = AppButton(title: confirmLabel, variant: .destructive)
        super.init(width: Self.width, onCancel: onCancel)
        embed(buildContent(message: message))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func focusInitialResponder() {
        switch start {
        case .onConfirm: focus(confirmButton)
        case .unfocused: window?.makeFirstResponder(self)
        }
    }

    override var acceptsFirstResponder: Bool { start == .unfocused }

    override func keyDown(with event: NSEvent) {
        guard KeyboardFocus.isFocused(self, in: window), case .tab(let shift) = KeyboardFocus.key(for: event) else {
            return super.keyDown(with: event)
        }
        focus(shift ? confirmButton : cancelButton)
    }

    override func reapplyTheme() {
        super.reapplyTheme()
        messageLabel.textColor = Theme.current.chrome.ink(.muted)
    }

    private func buildContent(message: String) -> NSStackView {
        messageLabel.font = ChromeType.font(.small)
        messageLabel.textColor = Theme.current.chrome.ink(.muted)
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.stringValue = message

        cancelButton.onTap = { [weak self] in self?.cancel() }
        confirmButton.onTap = { [weak self] in
            guard let self, !self.isDismissing else { return }
            self.onConfirm()
        }
        for button in [cancelButton, confirmButton] {
            button.isKeyboardFocusable = true
        }
        confirmButton.onArrowLeft = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onArrowRight = { [weak self] in self?.focus(self?.confirmButton) }
        confirmButton.onTab = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onTab = { [weak self] in self?.focus(self?.confirmButton) }
        cancelButton.onBacktab = { [weak self] in self?.focus(self?.confirmButton) }
        confirmButton.onBacktab = { [weak self] in self?.focus(self?.cancelButton) }

        let footer = ModalActionBar(trailing: [cancelButton, confirmButton])

        let content = NSStackView(views: [header, checklist ?? messageLabel, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = ChromeMetrics.Spacing.modalSectionGap
        content.edgeInsets = ChromeMetrics.Spacing.modalInsets
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(
                equalTo: content.widthAnchor,
                constant: -(ChromeMetrics.Spacing.modalInsets.left + ChromeMetrics.Spacing.modalInsets.right)
            ).isActive = true
        }
        return content
    }
}
