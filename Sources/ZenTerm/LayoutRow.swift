import AppKit

/// One Layout & Motion row: a caption (with an optional unit / "new tabs" note), an editing control,
/// and an inline validation message beneath it. The control is supplied and keyboard-wired by the
/// section; the row just lays it out and shows messages. A blank field is the default, so there's no
/// per-row reset control.
final class LayoutRow: NSView {
    private let messageLabel = NSTextField(labelWithString: "")

    init(caption: String, control: NSView, note: String?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.current.chrome.foreground.nsColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let captionView: NSView
        if let note {
            let noteLabel = NSTextField(labelWithString: note)
            noteLabel.font = .systemFont(ofSize: 10)
            noteLabel.textColor = Theme.current.chrome.ink(alpha: 0.4)
            let stack = NSStackView(views: [label, noteLabel])
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.alignment = .firstBaseline
            captionView = stack
        } else {
            captionView = label
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [captionView, spacer, control])
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
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            control.widthAnchor.constraint(equalToConstant: 180),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = (text == nil)
    }
}
