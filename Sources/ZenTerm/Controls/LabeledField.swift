import AppKit

/// A caption + control + inline validation message, stacked. The message sits directly beneath
/// its field and is hidden until `setMessage` gives it text. A shared form-control primitive.
final class LabeledField: NSView {
    /// Retained (not a throwaway init-local) so `reapplyTheme()` can recolor it — its color is
    /// baked into an attributed string this view has no insight into, so recoloring routes
    /// through `ThemeReapplying` when the caller's concrete caption type conforms.
    private let caption: NSView
    private let messageLabel = NSTextField(labelWithString: "")

    init(caption: NSView, control: NSView) {
        self.caption = caption
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

    /// Re-apply the live chrome colors after a config change — no relaunch. The message label's
    /// role is known here (`destructive`); the caption's isn't (it's an opaque `NSView`), so it
    /// only recolors when the concrete caption conforms to `ThemeReapplying`.
    func reapplyTheme() {
        messageLabel.textColor = Theme.current.chrome.destructive.nsColor
        (caption as? ThemeReapplying)?.reapplyTheme()
    }
}
