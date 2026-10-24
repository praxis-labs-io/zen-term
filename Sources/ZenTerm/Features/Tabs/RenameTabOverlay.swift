import AppKit

final class RenameTabOverlay: ModalShell, ModalOverlay {
    static let width: CGFloat = 380

    private let onSubmit: (String) -> Void

    private let header = NSTextField(labelWithString: "")
    private let nameField: FieldBox
    private let cancelButton = AppButton(title: "Cancel", variant: .secondary)
    private let renameButton = AppButton(title: "Rename", variant: .primary, keyEquivalent: "\r")

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

    func focusInitialResponder() {
        window?.makeFirstResponder(nameField.field)
        nameField.field.currentEditor()?.selectAll(nil)
    }

    override func reapplyTheme() {
        super.reapplyTheme()
        let chrome = Theme.current.chrome
        header.textColor = chrome.ink(.normal)
        let controls: [ThemeReapplying] = [nameField, cancelButton, renameButton]
        controls.forEach { $0.reapplyTheme() }
    }

    private func buildContent() -> NSStackView {
        header.font = ChromeType.font(.title)
        header.textColor = Theme.current.chrome.ink(.normal)
        header.stringValue = "Rename Tab"

        nameField.onEnter = { [weak self] in self?.submit() }
        nameField.onSubmit = { [weak self] in self?.submit() }

        cancelButton.onTap = { [weak self] in self?.cancel() }
        renameButton.onTap = { [weak self] in self?.submit() }
        for button in [cancelButton, renameButton] {
            button.isKeyboardFocusable = true
        }
        cancelButton.onArrowRight = { [weak self] in self?.focus(self?.renameButton) }
        renameButton.onArrowLeft = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onTab = { [weak self] in self?.focus(self?.renameButton) }
        renameButton.onTab = { [weak self] in self?.focus(self?.nameField.field) }
        renameButton.onBacktab = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onBacktab = { [weak self] in self?.focus(self?.nameField.field) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, cancelButton, renameButton])
        footer.orientation = .horizontal
        footer.spacing = ChromeMetrics.Spacing.s8
        footer.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [header, nameField, footer])
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
