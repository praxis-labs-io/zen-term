import AppKit

final class EnvRow: NSView {
    let keyBox = FieldBox(placeholder: "KEY")
    let valueBox = FieldBox(placeholder: "value")
    let removeButton = AppButton(title: "✕", variant: .secondary)
    private let equals = NSTextField(labelWithString: "=")

    var key: String { keyBox.text }
    var value: String { valueBox.text }

    init(onRemove: @escaping (EnvRow) -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        keyBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueBox.setContentHuggingPriority(.defaultLow, for: .horizontal)

        equals.font = .systemFont(ofSize: 13)
        equals.textColor = Theme.current.chrome.ink(.muted)
        equals.setContentHuggingPriority(.required, for: .horizontal)

        removeButton.setContentHuggingPriority(.required, for: .horizontal)
        removeButton.onTap = { [weak self] in if let self { onRemove(self) } }

        let stack = NSStackView(views: [keyBox, equals, valueBox, removeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            keyBox.widthAnchor.constraint(equalTo: valueBox.widthAnchor, multiplier: 0.6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        keyBox.reapplyTheme()
        valueBox.reapplyTheme()
        removeButton.reapplyTheme()
        equals.textColor = Theme.current.chrome.ink(.muted)
    }
}
