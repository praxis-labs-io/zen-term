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
    /// The finished message, the terminal it goes to, and what to do with it — `submit` (⏎, the
    /// default) sends and fires Return; `queue` (⌘⏎) stacks it in the input to add more first.
    typealias Send = (_ message: String, _ target: DiffSendTarget, _ action: DiffSendAction) -> Void

    private let reference: String
    private let removedLines: [String]
    private let targets: [DiffSendTarget]
    private let onSend: Send
    private let onCancel: () -> Void

    private let surface = NSView()
    private let noteScroll = NSScrollView()
    private let note = SubmitAwareTextView()
    private var targetDropdown: Dropdown!  // built in init once `self` can be captured
    private let submitButton = AppButton(title: "Submit", variant: .primary)
    private let queueButton = AppButton(title: "Queue", variant: .muted)
    private var closeButton: IconButton!  // built in init (its onClick needs self)

    /// The box's default height in the diff — the room the pane reserves for it before the note grows.
    /// Comfortable for a few lines; the note grows past it (up to `maxNoteLines`) as you type.
    static let height: CGFloat = 128
    private static let inset: CGFloat = 10

    /// The note grows a line at a time past `baseNoteLines` (which the default `height` already holds),
    /// then stops at `maxNoteLines` and scrolls inside itself — so a long note can't push the box over
    /// the whole diff.
    private static let baseNoteLines = 3
    private static let maxNoteLines = 8

    /// Fired when the note's line count crosses into a taller (or shorter) box, so the pane can
    /// re-reserve the room and re-push the lines below. Carries the box's new total height.
    var onRequestHeight: ((CGFloat) -> Void)?
    private var requestedHeight = DiffCommentComposer.height

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
        closeButton = IconButton(
            symbol: "xmark", size: NSSize(width: 22, height: 22), pointSize: 11,
            accessibilityLabel: "Close", onClick: { [weak self] in self?.onCancel() })

        submitButton.onTap = { [weak self] in self?.send(.submit) }
        queueButton.onTap = { [weak self] in self?.send(.queue) }
        wireFocusRing()

        let buttons = NSStackView(views: [queueButton, submitButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        let footer = NSStackView(views: [targetDropdown, NSView(), buttons])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false
        targetDropdown.setContentHuggingPriority(.defaultLow, for: .horizontal)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(noteScroll)
        surface.addSubview(footer)
        surface.addSubview(closeButton)
        // The box's own frame is set by the pane (a table subview), but everything inside lays out with
        // Auto Layout off that frame — the surface pinned into `self` with an inset, then the note above
        // the footer. `footer` hugs its content at the bottom so the note scroll takes the rest. The
        // close button floats in the top-right corner, above the note.
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

            closeButton.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -6),
            closeButton.topAnchor.constraint(equalTo: surface.topAnchor, constant: 6),
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
        // Off by default on a bare `NSTextView`, unlike a field editor, so Edit > Undo would grey out
        // here while it works in every single-line field (ZEN-370).
        note.allowsUndo = true
        note.font = .systemFont(ofSize: 13)
        note.textContainerInset = NSSize(width: 4, height: 4)
        note.isVerticallyResizable = true
        note.isHorizontallyResizable = false
        note.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        note.autoresizingMask = [.width]
        note.textContainer?.widthTracksTextView = true
        note.placeholder = "Leave a note"
        note.onSubmit = { [weak self] action in self?.send(action) }
        note.onCancel = { [weak self] in self?.onCancel() }
        note.onChange = { [weak self] in self?.updateHeight() }

        noteScroll.drawsBackground = false
        noteScroll.hasVerticalScroller = true
        noteScroll.verticalScroller = SlimScroller()
        noteScroll.autohidesScrollers = true
        noteScroll.documentView = note
        noteScroll.translatesAutoresizingMaskIntoConstraints = false

        applyNoteTheme()
    }

    private func buildTargetDropdown() -> Dropdown {
        Dropdown(
            items: targets.enumerated().map { index, target in
                DropdownItem(title: target.label, group: nil, note: nil, isSelected: index == 0)
            },
            selectedIndex: 0,
            onChange: { _ in })
    }

    /// One keyboard ring through the box, on Tab / Shift-Tab only. Tab runs the footer **right to
    /// left** so the very first Tab out of the note lands on Submit, the primary: note → Submit →
    /// Queue → target → note, wrapping. Shift-Tab reverses it.
    ///
    /// The footer deliberately claims **no** arrows: a Left/Right there falls through the responder
    /// chain to the diff pane, so the diff keeps panning horizontally with the box open — which is why
    /// the ring is Tab-driven, not arrow-driven. The note keeps its own arrows for the caret, and Down
    /// off its last line drops onto Submit. The close button isn't a ring stop — it's the mouse
    /// affordance for Esc.
    private func wireFocusRing() {
        [queueButton, submitButton].forEach { $0.isKeyboardFocusable = true }

        note.onTab = { [weak self] in self?.focus(self?.submitButton) }
        note.onBacktab = { [weak self] in self?.focusTarget() }
        note.onArrowDown = { [weak self] in self?.focus(self?.submitButton) }

        submitButton.onTab = { [weak self] in self?.focus(self?.queueButton) }
        submitButton.onBacktab = { [weak self] in self?.focusNote() }

        queueButton.onTab = { [weak self] in self?.focusTarget() }
        queueButton.onBacktab = { [weak self] in self?.focus(self?.submitButton) }

        targetDropdown.onTab = { [weak self] in self?.focusNote() }
        targetDropdown.onBacktab = { [weak self] in self?.focus(self?.queueButton) }
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
        guard let action = Self.sendShortcut(for: event) else { return false }
        send(action)
        return true
    }

    /// ⏎ (submit) / ⌘⏎ (queue), or nil for anything else — including ⇧⏎, which falls through so the
    /// text view takes a new line. The chat-input convention, because that's the muscle memory this box
    /// sits next to all day.
    ///
    /// Matched against the reservable set, never `deviceIndependentFlagsMask`, which keeps the extra
    /// bits AppKit stamps on and so never compares equal to a bare modifier (ZEN-81).
    static func sendShortcut(for event: NSEvent) -> DiffSendAction? {
        guard event.keyCode == 36 || event.keyCode == 76 else { return nil }  // Return, keypad Enter
        switch event.modifierFlags.intersection(DiffPaneTable.reservableModifiers) {
        case []: return .submit
        case .command: return .queue
        default: return nil
        }
    }

    private func send(_ action: DiffSendAction) {
        guard targets.indices.contains(targetDropdown.selectedIndex) else { return }
        let message = DiffComment.message(
            reference: reference, note: note.string, removedLines: removedLines)
        onSend(message, targets[targetDropdown.selectedIndex], action)
    }

    func reapplyTheme() {
        applySurfaceTheme()
        applyNoteTheme()
        targetDropdown.reapplyTheme()
        [queueButton, submitButton].forEach { $0.reapplyTheme() }
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

    /// Recompute the box height the note now wants and, if it changed the reserved room, ask the pane
    /// to grow (or shrink) around it. Only the crossings fire — typing within a line's worth of text
    /// doesn't re-tile the diff on every keystroke.
    private func updateHeight() {
        let height = boxHeight(forLines: noteLineCount)
        guard height != requestedHeight else { return }
        requestedHeight = height
        onRequestHeight?(height)
    }

    /// The laid-out line count of the note (at least 1), from the layout manager's used height.
    private var noteLineCount: Int {
        guard let layout = note.layoutManager, let container = note.textContainer else { return 1 }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        return max(1, Int((used / noteLineHeight).rounded()))
    }

    private var noteLineHeight: CGFloat {
        note.layoutManager?.defaultLineHeight(for: note.font ?? .systemFont(ofSize: 13)) ?? 16
    }

    /// The box height for `lines` of note: the default holds `baseNoteLines`, then each further line up
    /// to `maxNoteLines` adds one line-height; past that the note scrolls and the box stops growing.
    private func boxHeight(forLines lines: Int) -> CGFloat {
        let extra = max(0, min(lines, Self.maxNoteLines) - Self.baseNoteLines)
        return Self.height + CGFloat(extra) * noteLineHeight
    }

    private func focusNote() { window?.makeFirstResponder(note) }
    private func focusTarget() { window?.makeFirstResponder(targetDropdown) }
    private func focus(_ view: NSView?) {
        guard let view else { return }
        window?.makeFirstResponder(view)
    }

    // MARK: test hooks

    /// The message this box would send right now — asserted instead of the note's backing text, so a
    /// test covers the composition rule and not just the field.
    var messageForTesting: String {
        DiffComment.message(reference: reference, note: note.string, removedLines: removedLines)
    }
    var noteViewForTesting: NSTextView { note }
    var targetDropdownForTesting: Dropdown { targetDropdown }
    var submitButtonForTesting: AppButton { submitButton }
    var queueButtonForTesting: AppButton { queueButton }
    var selectedTargetForTesting: DiffSendTarget? {
        targets.indices.contains(targetDropdown.selectedIndex) ? targets[targetDropdown.selectedIndex] : nil
    }
}

/// The note's text view. ⏎ submits and ⌘⏎ queues (neither inserts), ⇧⏎ takes a new line, Esc cancels,
/// and Down from the last line leaves for the target picker — so the box is fully keyboard-driven and
/// the text view never swallows the send.
private final class SubmitAwareTextView: NSTextView {
    var onSubmit: ((_ action: DiffSendAction) -> Void)?
    var onCancel: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onChange: (() -> Void)?

    /// Shown when the note is empty. Drawn by the text view itself rather than as a floating label, so
    /// it lands exactly on the first glyph's origin (text-container inset + line-fragment padding) —
    /// a separate label can't track that origin and drifts off the cursor.
    var placeholder = ""
    var placeholderColor: NSColor = .clear { didSet { needsDisplay = true } }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true  // repaint so the placeholder clears the instant the first character lands
        onChange?()
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
        // ⇧⏎ is the new-line escape hatch; a bare Return submits, ⌘⏎ queues, and neither types.
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            super.insertNewline(sender)
            return
        }
        onSubmit?(NSApp.currentEvent?.modifierFlags.contains(.command) == true ? .queue : .submit)
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

    /// Tab moves focus out of the note rather than inserting a tab character — the note is one stop in
    /// the box's focus ring, not a place to indent.
    override func insertTab(_ sender: Any?) {
        guard let onTab else {
            super.insertTab(sender)
            return
        }
        onTab()
    }

    override func insertBacktab(_ sender: Any?) {
        guard let onBacktab else {
            super.insertBacktab(sender)
            return
        }
        onBacktab()
    }
}
