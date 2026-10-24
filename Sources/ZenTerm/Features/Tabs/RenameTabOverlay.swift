import AppKit

final class RenameTabOverlay: ModalShell, ModalOverlay {
    static let width: CGFloat = 380

    private let onSubmit: (String) -> Void

    private let header = NSTextField(labelWithString: "")
    private let nameField: FieldBox
    private let cancelButton: IconButton
    private let saveButton: IconButton

    init(
        current: String, liveTitle: String,
        onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        nameField = FieldBox(placeholder: liveTitle)
        let buttonSize = NSSize(width: ChromeMetrics.Height.control, height: ChromeMetrics.Height.control)
        cancelButton = IconButton(symbol: "xmark", size: buttonSize, accessibilityLabel: "Cancel", onClick: {})
        saveButton = IconButton(symbol: "checkmark", size: buttonSize, accessibilityLabel: "Rename", onClick: {})
        super.init(width: Self.width, onCancel: onCancel)
        nameField.setText(current)
        cancelButton.onClick = { [weak self] in self?.cancel() }
        saveButton.onClick = { [weak self] in self?.submit() }
        embed(buildContent())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var nameFieldForTesting: FieldBox { nameField }
    var saveButtonForTesting: IconButton { saveButton }
    var cancelButtonForTesting: IconButton { cancelButton }

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
        saveButton.reapplyTheme()
    }

    private func buildContent() -> NSStackView {
        header.font = ChromeType.font(.title)
        header.textColor = Theme.current.chrome.ink(.normal)
        header.stringValue = "Rename Tab"

        nameField.onEnter = { [weak self] in self?.submit() }
        nameField.onSubmit = { [weak self] in self?.submit() }

        for button in [cancelButton, saveButton] { button.firesOnRelease = true }

        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let inputRow = NSStackView(views: [nameField, cancelButton, saveButton])
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

    private func submit() {
        guard !isDismissing else { return }
        onSubmit(nameField.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
