import AppKit

final class RenameTabOverlay: ModalShell, ModalOverlay {
    static let width: CGFloat = 380

    private let onSubmit: (String) -> Void

    private let header = ModalHeader(title: "Rename Tab")
    private let nameField: FieldBox
    private let footer = HintFooter([.init(keys: "⏎", label: "Save"), .init(keys: "⎋", label: "Cancel")])

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

    func focusInitialResponder() {
        window?.makeFirstResponder(nameField.field)
        nameField.field.currentEditor()?.selectAll(nil)
    }

    private func buildContent() -> NSStackView {
        nameField.onEnter = { [weak self] in self?.submit() }
        nameField.onSubmit = { [weak self] in self?.submit() }

        let content = NSStackView(views: [header, nameField])
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

        let card = NSStackView(views: [content, footer])
        card.translatesAutoresizingMaskIntoConstraints = false
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 0
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: card.widthAnchor),
            footer.widthAnchor.constraint(equalTo: card.widthAnchor),
        ])
        return card
    }

    private func submit() {
        guard !isDismissing else { return }
        onSubmit(nameField.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
