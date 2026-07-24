import AppKit

/// The diff viewer's comment box (ZEN-257): a note field that drops into the diff directly under the
/// selected lines, pushing the lines below it down, the way a review comment reads on a pull request
/// with the code still on screen above it.
///
/// ⏎ sends, ⌘⏎ sends and submits, ⇧⏎ takes a new line, Esc cancels. The Send / Send + submit buttons
/// do the same for the mouse.
///
/// Deliberately not a card: it sits *in* the diff, so it wears a muted surface fill (opaque, so the
/// diff behind it doesn't bleed through the footer), no header, no title. The selection above it says
/// what it's about, which is why there's no reference line to read.
///
/// It owns none of the sending. It hands back a finished message and the chosen terminal; the viewer
/// closes and `TabController` does the paste.
final class DiffCommentComposer: NSView {
    /// The finished message, the terminal it goes to, and whether to submit it (⌘⏎) rather than just
    /// leave it in the input (⏎).
    typealias Send = (_ message: String, _ target: DiffSendTarget, _ submit: Bool) -> Void

    private let reference: String
    private let removedLines: [String]
    private let targets: [DiffSendTarget]
    private let onSend: Send
    private let onCancel: () -> Void

    private let surface = NSView()
    private let noteScroll = NSScrollView()
    private let note = SubmitAwareTextView()
    private var targetDropdown: Dropdown!  // built in init once `self` can be captured
    private let sendButton = AppButton(title: "Send", variant: .primary)
    private let submitButton = AppButton(title: "Send + submit", variant: .muted)
    private let cancelButton = AppButton(title: "Cancel", variant: .secondary)

    /// How tall the box is in the diff — the room the pane reserves for it. Fixed rather than
    /// content-driven: a box that grew as you typed would re-push the lines under it on every keystroke.
    static let height: CGFloat = 128
    private static let inset: CGFloat = 10

    init(
        reference: String, removedLines: [String], targets: [DiffSendTarget],
        onSend: @escaping Send, onCancel: @escaping () -> Void
    ) {
        self.reference = reference
        self.removedLines = removedLines
        self.targets = targets
        self.onSend = onSend
        self.onCancel = onCancel
        super.init(frame: .zero)
        wantsLayer = true

        buildSurface()
        buildNote()
        targetDropdown = buildTargetDropdown()

        sendButton.onTap = { [weak self] in self?.send(submit: false) }
        submitButton.onTap = { [weak self] in self?.send(submit: true) }
        cancelButton.onTap = { [weak self] in self?.onCancel() }

        let buttons = NSStackView(views: [cancelButton, submitButton, sendButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        let footer = NSStackView(views: [targetDropdown, NSView(), buttons])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false
        targetDropdown.setContentHuggingPriority(.defaultLow, for: .horizontal)

        surface.addSubview(noteScroll)
        surface.addSubview(footer)
        // The box's own frame is set by the pane (a table subview), but everything inside lays out with
        // Auto Layout off that frame — the surface pinned into `self` with an inset, then the note above
        // the footer. `footer` hugs its content at the bottom so the note scroll takes the rest.
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            surface.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),

            noteScroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12),
            noteScroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
            noteScroll.topAnchor.constraint(equalTo: surface.topAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: noteScroll.bottomAnchor, constant: 8),
            footer.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -10),
            targetDropdown.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: build

    private func buildSurface() {
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 8
        surface.translatesAutoresizingMaskIntoConstraints = false
        applySurfaceTheme()
        addSubview(surface)
    }

    private func buildNote() {
        note.isRichText = false
        note.drawsBackground = false
        note.font = .systemFont(ofSize: 13)
        note.textContainerInset = NSSize(width: 4, height: 4)
        note.isVerticallyResizable = true
        note.isHorizontallyResizable = false
        note.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        note.autoresizingMask = [.width]
        note.textContainer?.widthTracksTextView = true
        note.placeholder = "Leave a note"
        note.onSubmit = { [weak self] submit in self?.send(submit: submit) }
        note.onCancel = { [weak self] in self?.onCancel() }
        note.onArrowDown = { [weak self] in self?.focusTarget() }

        noteScroll.drawsBackground = false
        noteScroll.hasVerticalScroller = true
        noteScroll.verticalScroller = SlimScroller()
        noteScroll.autohidesScrollers = true
        noteScroll.documentView = note
        noteScroll.translatesAutoresizingMaskIntoConstraints = false

        applyNoteTheme()
    }

    private func buildTargetDropdown() -> Dropdown {
        let dropdown = Dropdown(
            items: targets.enumerated().map { index, target in
                DropdownItem(title: target.label, group: nil, note: nil, isSelected: index == 0)
            },
            selectedIndex: 0,
            onChange: { _ in })
        dropdown.onArrowUp = { [weak self] in self?.focusNote() }
        return dropdown
    }

    // MARK: lifecycle

    func focusInitialResponder() { window?.makeFirstResponder(note) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }

    /// Keystrokes the box claims while it's up. Also called by the viewer *before* its own handlers:
    /// the viewer is this view's ancestor, so its `performKeyEquivalent` runs first, and without that
    /// early route its Esc would close the whole viewer and its ⌘C would yank the diff out from under
    /// a note being typed.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        // An open dropdown list owns Return and Esc for itself (commit / close). Claiming them here
        // would close the box out from under an open list — the ZEN-5 layered-dismissal rule.
        guard !targetDropdown.isPopoverOpen else { return false }
        if KeyboardFocus.key(for: event) == .escape {
            onCancel()
            return true
        }
        guard let submit = Self.sendShortcut(for: event) else { return false }
        send(submit: submit)
        return true
    }

    /// ⏎ (send) / ⌘⏎ (send and submit), or nil for anything else — including ⇧⏎, which falls through
    /// so the text view takes a new line. The chat-input convention, because that's the muscle memory
    /// this box sits next to all day.
    ///
    /// Matched against the reservable set, never `deviceIndependentFlagsMask`, which keeps the extra
    /// bits AppKit stamps on and so never compares equal to a bare modifier (ZEN-145).
    static func sendShortcut(for event: NSEvent) -> Bool? {
        guard event.keyCode == 36 || event.keyCode == 76 else { return nil }  // Return, keypad Enter
        switch event.modifierFlags.intersection(DiffPaneTable.reservableModifiers) {
        case []: return false
        case .command: return true
        default: return nil
        }
    }

    private func send(submit: Bool) {
        guard targets.indices.contains(targetDropdown.selectedIndex) else { return }
        let message = DiffComment.message(
            reference: reference, note: note.string, removedLines: removedLines)
        onSend(message, targets[targetDropdown.selectedIndex], submit)
    }

    func reapplyTheme() {
        applySurfaceTheme()
        applyNoteTheme()
        targetDropdown.reapplyTheme()
        [sendButton, submitButton, cancelButton].forEach { $0.reapplyTheme() }
    }

    // MARK: theming

    /// An opaque, muted surface: the diff's own background lifted a touch, so the box reads as sitting
    /// on the diff rather than a bright card over it, and nothing shows through behind the footer.
    private func applySurfaceTheme() {
        let chrome = Theme.current.chrome
        surface.layer?.backgroundColor =
            chrome.background.nsColor.blended(
                withFraction: 0.06, of: chrome.foreground.nsColor)?.cgColor
        surface.layer?.borderWidth = 1
        surface.layer?.borderColor = chrome.ink(alpha: 0.12).cgColor
    }

    private func applyNoteTheme() {
        let chrome = Theme.current.chrome
        note.textColor = chrome.foreground.nsColor
        note.insertionPointColor = chrome.foreground.nsColor
        note.placeholderColor = chrome.ink(alpha: 0.4)
    }

    private func focusNote() { window?.makeFirstResponder(note) }
    private func focusTarget() { window?.makeFirstResponder(targetDropdown) }

    // MARK: test hooks

    /// The message this box would send right now — asserted instead of the note's backing text, so a
    /// test covers the composition rule and not just the field.
    var messageForTesting: String {
        DiffComment.message(reference: reference, note: note.string, removedLines: removedLines)
    }
    var noteViewForTesting: NSTextView { note }
    var targetDropdownForTesting: Dropdown { targetDropdown }
    var sendButtonForTesting: AppButton { sendButton }
    var submitButtonForTesting: AppButton { submitButton }
    var selectedTargetForTesting: DiffSendTarget? {
        targets.indices.contains(targetDropdown.selectedIndex) ? targets[targetDropdown.selectedIndex] : nil
    }
}

/// The note's text view. ⏎ and ⌘⏎ submit (they never insert), ⇧⏎ takes a new line, Esc cancels, and
/// Down from the last line leaves for the target picker — so the box is fully keyboard-driven and the
/// text view never swallows the send.
private final class SubmitAwareTextView: NSTextView {
    var onSubmit: ((_ submit: Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onArrowDown: (() -> Void)?

    /// Shown when the note is empty. Drawn by the text view itself rather than as a floating label, so
    /// it lands exactly on the first glyph's origin (text-container inset + line-fragment padding) —
    /// a separate label can't track that origin and drifts off the cursor.
    var placeholder = ""
    var placeholderColor: NSColor = .clear { didSet { needsDisplay = true } }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true  // repaint so the placeholder clears the instant the first character lands
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }
        let x = textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)
        placeholder.draw(
            at: NSPoint(x: x, y: textContainerInset.height),
            withAttributes: [.font: font, .foregroundColor: placeholderColor])
    }

    override func insertNewline(_ sender: Any?) {
        // ⇧⏎ is the new-line escape hatch; a bare (or ⌘) Return submits and never types.
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            super.insertNewline(sender)
            return
        }
        onSubmit?(NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func moveDown(_ sender: Any?) {
        guard let onArrowDown, selectedRange() == NSRange(location: (string as NSString).length, length: 0)
        else {
            super.moveDown(sender)
            return
        }
        onArrowDown()
    }
}
