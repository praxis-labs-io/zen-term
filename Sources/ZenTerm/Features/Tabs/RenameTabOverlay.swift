import AppKit

final class RenameTabOverlay: ModalShell, ModalOverlay {
    static let width: CGFloat = 380

    private let onSubmit: (String) -> Void

    private let header = NSTextField(labelWithString: "")
    private let nameField: FieldBox
    private lazy var cancelButton = AppButton(variant: .muted, symbol: "xmark") { [weak self] in self?.cancel() }
    private lazy var renameButton = AppButton(variant: .primary, symbol: "checkmark") { [weak self] in
        self?.submit()
    }

    init(
        current: String, liveTitle: String,
        onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        nameField = FieldBox(placeholder: liveTitle)
        super.init(width: Self.width, onCancel: onCancel)
        nameField.setText(current)
        embed(buildContent())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var nameFieldForTesting: FieldBox { nameField }
    var renameButtonForTesting: AppButton { renameButton }
    var cancelButtonForTesting: AppButton { cancelButton }

    func focusInitialResponder() {
        window?.makeFirstResponder(nameField.field)
        nameField.field.currentEditor()?.selectAll(nil)
    }

    override func reapplyTheme() {
        super.reapplyTheme()
        let chrome = Theme.current.chrome
        header.textColor = chrome.ink(.normal)
        nameField.reapplyTheme()
        cancelButton.reapplyTheme()
        renameButton.reapplyTheme()
    }

    private func buildContent() -> NSStackView {
        header.font = ChromeType.font(.title)
        header.textColor = Theme.current.chrome.ink(.normal)
        header.stringValue = "Rename Tab"

        nameField.onEnter = { [weak self] in self?.submit() }
        nameField.onSubmit = { [weak self] in self?.submit() }

        cancelButton.setAccessibilityLabel("Cancel")
        renameButton.setAccessibilityLabel("Rename")
        for button in [cancelButton, renameButton] { button.isKeyboardFocusable = true }
        cancelButton.onArrowRight = { [weak self] in self?.focus(self?.renameButton) }
        renameButton.onArrowLeft = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onTab = { [weak self] in self?.focus(self?.renameButton) }
        renameButton.onTab = { [weak self] in self?.focus(self?.nameField.field) }
        renameButton.onBacktab = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onBacktab = { [weak self] in self?.focus(self?.nameField.field) }
        nameField.onTab = { [weak self] in self?.focus(self?.cancelButton) }
        nameField.onBacktab = { [weak self] in self?.focus(self?.renameButton) }

        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let inputRow = NSStackView(views: [nameField, cancelButton, renameButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = ChromeMetrics.Spacing.s8
        inputRow.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [header, inputRow])
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

    private func focus(_ view: NSView?) {
        guard let view else { return }
        window?.makeFirstResponder(view)
    }

    private func submit() {
        guard !isDismissing else { return }
        onSubmit(nameField.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
