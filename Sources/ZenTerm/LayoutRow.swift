import AppKit

final class LayoutRow: NSView {
    enum MessageKind { case diagnostic, failure }

    private let captionLabel: NSTextField
    private let descriptionLabel: NSTextField?
    private let controlNoteLabel: NSTextField?
    private let messageLabel = NSTextField(labelWithString: "")
    private(set) var messageKind: MessageKind?

    init(caption: String, description: String?, control: NSView, controlNote: String?, controlWidth: CGFloat?) {
        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.current.chrome.foreground.nsColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let (captionColumn, descriptionNote) = LayoutRow.column(primary: label, note: description, alignment: .leading)
        let (controlColumn, controlNoteField) = LayoutRow.column(
            primary: control, note: controlNote, alignment: .trailing)

        captionLabel = label
        descriptionLabel = descriptionNote
        controlNoteLabel = controlNoteField

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

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

    private static func column(
        primary: NSView, note: String?, alignment: NSLayoutConstraint.Attribute
    ) -> (NSView, NSTextField?) {
        guard let note else { return (primary, nil) }
        let noteLabel = NSTextField(labelWithString: note)
        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = Theme.current.chrome.ink(.muted)
        let stack = NSStackView(views: [primary, noteLabel])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = alignment
        return (stack, noteLabel)
    }

    func showMessage(_ text: String?, kind: MessageKind = .failure) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = (text == nil)
        messageKind = (text == nil) ? nil : kind
        messageLabel.textColor = LayoutRow.ink(for: messageKind)
    }

    private static func ink(for kind: MessageKind?) -> NSColor {
        switch kind {
        case .diagnostic: return Theme.current.chrome.warning.nsColor
        case .failure, nil: return Theme.current.chrome.destructive.nsColor
        }
    }

    var renderedMessageForTesting: String? {
        messageLabel.isHidden ? nil : messageLabel.stringValue
    }

    func reapplyTheme() {
        captionLabel.textColor = Theme.current.chrome.foreground.nsColor
        descriptionLabel?.textColor = Theme.current.chrome.ink(.muted)
        controlNoteLabel?.textColor = Theme.current.chrome.ink(.muted)
        messageLabel.textColor = LayoutRow.ink(for: messageKind)
    }
}
