import AppKit

/// A caption + control + inline validation message, stacked. The message sits directly beneath
/// its field and is hidden until `setMessage` gives it text. A shared form-control primitive.
final class LabeledField: NSView {
    private let messageLabel = NSTextField(labelWithString: "")

    init(caption: NSView, control: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 11, weight: .medium)
        messageLabel.textColor = Theme.current.chrome.destructive.nsColor
        messageLabel.isHidden = true

        let stack = NSStackView(views: [caption, control, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for view in [caption, control, messageLabel] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = (text == nil)
    }
}
