import AppKit

/// One Layout & Motion row: a caption with an optional description beneath it on the left, an editing
/// control on the right with an optional note beneath it (e.g. the valid range), and an inline
/// validation message under the whole row. The control is supplied and keyboard-wired by the section.
final class LayoutRow: NSView {
    /// Why the row is showing a message, which decides its ink. A `.diagnostic` (a config value the
    /// file asked for and got a fallback of) reads as a warning; a `.failure` (an invalid live edit
    /// or a write that didn't land) reads destructive. Rendering a working-but-clamped config in the
    /// same red as "couldn't write config" would teach the user to read both as breakage.
    enum MessageKind { case diagnostic, failure }

    /// Retained (not throwaway locals) so `reapplyTheme()` can recolor them in place — the section
    /// recolors the mounted detail rather than rebuilding it, so nothing here may go stranded.
    private let captionLabel: NSTextField
    private let descriptionLabel: NSTextField?
    private let controlNoteLabel: NSTextField?
    private let messageLabel = NSTextField(labelWithString: "")
    private var messageKind: MessageKind?

    init(caption: String, description: String?, control: NSView, controlNote: String?, controlWidth: CGFloat?) {
        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.current.chrome.foreground.nsColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Hug the control to its content so it never stretches to fill the row — the spacer then
        // pushes it to the trailing edge. Without this a `SegmentedControl` (which pins its segments
        // leading) expands and its buttons float mid-row instead of aligning right like the fields.
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let (captionColumn, descriptionNote) = LayoutRow.column(primary: label, note: description, alignment: .leading)
        let (controlColumn, controlNoteField) = LayoutRow.column(
            primary: control, note: controlNote, alignment: .trailing)

        // Own stored properties must be set before delegating to `super.init` (two-phase init).
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

    /// A `primary` view with an optional muted `note` label stacked beneath it (the range under an
    /// input, the description under a caption). Returns `primary` alone (and a nil note) when
    /// there's no note; the note label is returned too so the caller can retain it for recoloring.
    private static func column(
        primary: NSView, note: String?, alignment: NSLayoutConstraint.Attribute
    ) -> (NSView, NSTextField?) {
        guard let note else { return (primary, nil) }
        let noteLabel = NSTextField(labelWithString: note)
        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = Theme.current.chrome.ink(alpha: 0.4)
        let stack = NSStackView(views: [primary, noteLabel])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = alignment
        return (stack, noteLabel)
    }

    /// Show (or clear, with nil) the row's inline message. `.failure` (the default) keeps the
    /// existing live-validation / write-error tone; `.diagnostic` marks a config-file value the
    /// parser fell back on, which reads as a warning rather than breakage.
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

    /// Test hook: the inline message as actually rendered — nil when the label is hidden. Reads the
    /// label rather than a backing property, so a test can't pass while the row shows nothing.
    var renderedMessageForTesting: String? {
        messageLabel.isHidden ? nil : messageLabel.stringValue
    }

    /// Re-apply the live chrome colors after a config change — no relaunch. Matches the exact
    /// roles set at construction: caption foreground, both note labels at `ink(0.4)`, message tone
    /// by its current kind.
    func reapplyTheme() {
        captionLabel.textColor = Theme.current.chrome.foreground.nsColor
        descriptionLabel?.textColor = Theme.current.chrome.ink(alpha: 0.4)
        controlNoteLabel?.textColor = Theme.current.chrome.ink(alpha: 0.4)
        messageLabel.textColor = LayoutRow.ink(for: messageKind)
    }
}
