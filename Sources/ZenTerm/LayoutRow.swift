import AppKit

/// One Layout & Motion row: a caption with an optional description beneath it on the left, an editing
/// control on the right with an optional note beneath it (e.g. the valid range), and an inline
/// validation message under the whole row. The control is supplied and keyboard-wired by the section.
final class LayoutRow: NSView {
    private let messageLabel = NSTextField(labelWithString: "")

    init(caption: String, description: String?, control: NSView, controlNote: String?, controlWidth: CGFloat?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.current.chrome.foreground.nsColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let captionColumn = LayoutRow.column(primary: label, note: description, alignment: .leading)
        let controlColumn = LayoutRow.column(primary: control, note: controlNote, alignment: .trailing)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [captionColumn, spacer, controlColumn])
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
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ]
        if let controlWidth {
            constraints.append(control.widthAnchor.constraint(equalToConstant: controlWidth))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A `primary` view with an optional muted `note` label stacked beneath it (the range under an
    /// input, the description under a caption). Returns `primary` alone when there's no note.
    private static func column(
        primary: NSView, note: String?, alignment: NSLayoutConstraint.Attribute
    ) -> NSView {
        guard let note else { return primary }
        let noteLabel = NSTextField(labelWithString: note)
        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = Theme.current.chrome.ink(alpha: 0.4)
        let stack = NSStackView(views: [primary, noteLabel])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = alignment
        return stack
    }

    func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = (text == nil)
    }
}
