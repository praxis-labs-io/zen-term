import AppKit

final class ConfirmCard: ModalShell, ModalOverlay {
    static let width: CGFloat = 420

    private let onConfirm: () -> Void

    private let header = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let checklist: ConfirmCardChecklist?
    private let cancelButton = AppButton(title: "Cancel", variant: .secondary)
    private let confirmButton: AppButton

    convenience init(
        title: String, message: String, confirmLabel: String,
        onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void
    ) {
        self.init(
            title: title, message: message, checklist: nil, confirmLabel: confirmLabel,
            onCancel: onCancel, onConfirm: onConfirm)
    }

    convenience init(
        title: String, items: [ConfirmCardChecklist.Item], confirmLabel: String,
        onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void
    ) {
        self.init(
            title: title, message: "", checklist: ConfirmCardChecklist(items: items), confirmLabel: confirmLabel,
            onCancel: onCancel, onConfirm: onConfirm)
    }

    private init(
        title: String, message: String, checklist: ConfirmCardChecklist?, confirmLabel: String,
        onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void
    ) {
        self.checklist = checklist
        self.onConfirm = onConfirm
        confirmButton = AppButton(title: confirmLabel, variant: .destructive)
        super.init(width: Self.width, onCancel: onCancel)
        embed(buildContent(title: title, message: message))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func focusInitialResponder() { window?.makeFirstResponder(confirmButton) }

    override func reapplyTheme() {
        super.reapplyTheme()
        let chrome = Theme.current.chrome
        header.textColor = chrome.ink(.normal)
        messageLabel.textColor = chrome.ink(.muted)
        checklist?.reapplyTheme()
        cancelButton.reapplyTheme()
        confirmButton.reapplyTheme()
    }

    private func buildContent(title: String, message: String) -> NSStackView {
        header.font = ChromeType.font(.title)
        header.textColor = Theme.current.chrome.ink(.normal)
        header.stringValue = title

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

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, cancelButton, confirmButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = ChromeMetrics.Spacing.s8

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
