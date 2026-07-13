import AppKit

/// The add / edit form for a tool float, opened from the Settings → Tools section. It collects a
/// float's fields — id, title, icon, shortcut, command, size, and a git-only toggle — builds a
/// `ToolFloat`, and hands it to `onSubmit` (the host writes it via `ConfigWriter` + reloads, so the
/// dock button, ⌘P entry, and its keybind appear with no restart). A `ModalOverlay` like the
/// palettes and `AddWorkspaceOverlay`, which it mirrors; `emptyGuard` has no config grammar yet, so
/// it isn't editable here (an existing float's guard, always nil today, is preserved untouched).
///
/// Fully keyboard-driven: Up/Down move between fields, the shortcut chip captures a chord (Return to
/// arm, then press keys; Backspace clears), Return advances, ⌘Return submits, Esc cancels. Every
/// input is full width, and each field shows its own validation message beneath it.
final class ToolFloatFormOverlay: NSView, ModalOverlay {
    private let editingFloat: ToolFloat?
    private let existingIDs: Set<String>
    private let capturer: KeybindCapturing?
    private let onSubmit: (ToolFloat) -> Void
    private let onCancel: () -> Void

    private let card = CardView()
    private var dismiss = DismissGate()
    /// Retained (not a throwaway init-local) so `reapplyTheme()` can recolor it in place.
    private let header = NSTextField(labelWithString: "")

    private let idField = FieldBox(placeholder: "gitdash")
    private let titleField = FieldBox(placeholder: "Open GitDash")
    private var iconPicker: IconPickerField!
    private let chordChip = KeybindChip()
    private let commandField = FieldBox(placeholder: "npm run dev")
    private let widthField = FieldBox(placeholder: "0.85")
    private let heightField = FieldBox(placeholder: "0.85")
    private let gitSegment = SegmentedControl(options: ["Any folder", "Git repos only"], selectedIndex: 0) { _ in }

    private var idGroup: LabeledField?
    private var titleGroup: LabeledField?
    private var iconGroup: LabeledField?
    private var chordGroup: LabeledField?
    private var commandGroup: LabeledField?
    private var sizeGroup: LabeledField?

    /// Captions built directly into a stack (not wrapped by a `LabeledField`, which retains its own).
    /// Retained so `reapplyTheme()` can reach them after a live theme swap while the form is open.
    private var captions: [FieldCaption] = []

    /// The chord captured for the shortcut, or nil until one is recorded. The float's single source
    /// of truth for its key — rendered into the chip and written as the `key:` token.
    private var capturedChord: Chord?

    private let cancelButton = AppButton(title: "Cancel", variant: .secondary, keyEquivalent: "\u{1b}")
    private let submitButton = AppButton(
        title: "", variant: .primary, keyEquivalent: "\r", keyEquivalentModifierMask: .command)

    init(
        editing: ToolFloat?, existingIDs: Set<String>, capturer: KeybindCapturing?, background: NSColor,
        onSubmit: @escaping (ToolFloat) -> Void, onCancel: @escaping () -> Void
    ) {
        self.editingFloat = editing
        self.existingIDs = existingIDs
        self.capturer = capturer
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let backdrop = BackdropView(onClick: onCancel)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        CardChrome.apply(to: card, background: background)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let content = buildContent()
        card.addSubview(content)

        let cardWidth = card.widthAnchor.constraint(equalToConstant: 460)
        cardWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            cardWidth,
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.92),
            card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.92),

            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        prefill()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: ModalOverlay

    func focusInitialResponder() { window?.makeFirstResponder(idField.field) }

    func animateIn() {
        superview?.layoutSubtreeIfNeeded()  // resolve the card's frame before scaling about its center
        Motion.springScaleFade(card, appearing: true)
    }

    func animateOut(completion: @escaping () -> Void) {
        guard dismiss.begin() else { return }
        capturer?.endCapture()  // never leave a capture handler armed after the form closes
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        dismiss.isDismissing ? nil : super.hitTest(point)
    }

    /// Re-apply the form's theme-dependent colors after a live theme change, IN PLACE — this form
    /// holds uncommitted typed values a rebuild would lose, so nothing here is rebuilt, only
    /// recolored. Every leaf control conforms to `ThemeReapplying`, so they recolor as one group.
    func reapplyTheme() {
        CardChrome.reapplyTheme(to: card)
        header.textColor = Theme.current.chrome.foreground.nsColor

        let controls: [ThemeReapplying] = [
            idField, titleField, commandField, widthField, heightField, gitSegment,
            cancelButton, submitButton,
        ]
        controls.forEach { $0.reapplyTheme() }
        chordChip.reapplyTheme()
        iconPicker.reapplyTheme()
        for group in [idGroup, titleGroup, iconGroup, chordGroup, commandGroup, sizeGroup] {
            group?.reapplyTheme()
        }
        captions.forEach { $0.reapplyTheme() }
    }

    // MARK: content

    private func buildContent() -> NSStackView {
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = Theme.current.chrome.foreground.nsColor
        header.stringValue = editingFloat == nil ? "New Tool Float" : "Edit Tool Float"

        wireField(idField)
        idField.onChange = { [weak self] in self?.refreshValidity() }
        let idGroup = LabeledField(caption: caption("ID", required: true), control: idField)
        self.idGroup = idGroup

        wireField(titleField)
        let titleGroup = LabeledField(caption: caption("TITLE", required: false), control: titleField)
        self.titleGroup = titleGroup

        let picker = IconPickerField(selected: editingFloat?.icon ?? IconCatalog.defaultSymbol)
        picker.onChange = { [weak self] _ in self?.refreshValidity() }
        picker.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        picker.onArrowDown = { [weak self] in self?.moveVertical(1) }
        picker.onEsc = { [weak self] in self?.onCancel() }
        iconPicker = picker
        let iconGroup = LabeledField(caption: caption("ICON", required: false), control: picker)
        self.iconGroup = iconGroup

        chordChip.onActivate = { [weak self] in self?.beginCapture() }
        chordChip.onReset = { [weak self] in self?.clearChord() }
        chordChip.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        chordChip.onArrowDown = { [weak self] in self?.moveVertical(1) }
        chordChip.onEsc = { [weak self] in self?.onCancel() }
        // The chip is a fixed 110pt; a bare `LabeledField` would pin that width to the whole group
        // (required) and collapse the card. Wrap it in a leading row so the group fills width while
        // the chip keeps its natural size.
        let chordSpacer = NSView()
        chordSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let chordRow = Self.hStack([chordChip, chordSpacer], spacing: 0)
        let chordGroup = LabeledField(caption: caption("SHORTCUT", required: true), control: chordRow)
        self.chordGroup = chordGroup

        wireField(commandField)
        commandField.onChange = { [weak self] in self?.refreshValidity() }
        let commandGroup = LabeledField(caption: caption("COMMAND", required: true), control: commandField)
        self.commandGroup = commandGroup

        // Width × Height share one row (a fraction of the tile). Width is the row's vertical stop;
        // Height is reached with Right (like an env row's value box).
        for box in [widthField, heightField] { wireField(box) }
        widthField.onChange = { [weak self] in self?.refreshValidity() }
        heightField.onChange = { [weak self] in self?.refreshValidity() }
        widthField.onArrowRight = { [weak self] in self?.focus(self?.heightField.field) }
        heightField.onArrowLeft = { [weak self] in self?.focus(self?.widthField.field) }
        let times = NSTextField(labelWithString: "×")
        times.font = .systemFont(ofSize: 13)
        times.textColor = Theme.current.chrome.ink(alpha: 0.4)
        times.setContentHuggingPriority(.required, for: .horizontal)
        // Two compact, equal-width fields left-aligned; a trailing spacer absorbs the rest of the
        // group so they don't stretch to the full card width.
        let sizeSpacer = NSView()
        sizeSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sizeRow = Self.hStack([widthField, times, heightField, sizeSpacer], spacing: 8)
        widthField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        heightField.widthAnchor.constraint(equalTo: widthField.widthAnchor).isActive = true
        let sizeGroup = LabeledField(caption: caption("SIZE (FRACTION OF TILE)", required: false), control: sizeRow)
        self.sizeGroup = sizeGroup

        wireSegment(gitSegment)
        let gitGroup = Self.vStack([caption("OPEN IN", required: false), gitSegment], spacing: 6)

        cancelButton.onTap = { [weak self] in self?.onCancel() }
        submitButton.setTitle(editingFloat == nil ? "Add Tool Float" : "Save")
        submitButton.onTap = { [weak self] in self?.submit() }
        for button in [cancelButton, submitButton] {
            button.isKeyboardFocusable = true
            button.onArrowUp = { [weak self] in self?.moveVertical(-1) }
            button.onArrowDown = { [weak self] in self?.moveVertical(1) }
            button.onEsc = { [weak self] in self?.onCancel() }
        }
        submitButton.onArrowLeft = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onArrowRight = { [weak self] in self?.focus(self?.submitButton) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = Self.hStack([spacer, cancelButton, submitButton], spacing: 8)

        let content = NSStackView(views: [
            header, idGroup, titleGroup, iconGroup, chordGroup, commandGroup, sizeGroup, gitGroup, footer,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        }
        return content
    }

    /// Seed the fields from the float being edited (all blank for a new float). The chord renders
    /// into the chip; blank optional fields show their placeholder default.
    private func prefill() {
        chordChip.render(shortcut: "")
        guard let float = editingFloat else { return }
        idField.setText(float.id)
        if float.title != ToolFloatParser.defaultTitle(forID: float.id) { titleField.setText(float.title) }
        capturedChord = float.toggle
        chordChip.render(shortcut: float.toggle.displayGlyph)
        commandField.setText(float.command)
        if float.widthFraction != ToolFloatParser.defaultFraction {
            widthField.setText(Self.fractionText(float.widthFraction))
        }
        if float.heightFraction != ToolFloatParser.defaultFraction {
            heightField.setText(Self.fractionText(float.heightFraction))
        }
        gitSegment.setSelection(float.requiresGitRepo ? 1 : 0)
    }

    // MARK: chord capture

    /// Arm the shortcut chip: record the next chord through the interceptor (so an already-bound
    /// chord isn't pre-empted). An invalid chord (no modifier) shows a message and stays armed; a
    /// valid one commits and disarms. Esc cancels; Backspace clears.
    private func beginCapture() {
        guard let capturer else {
            chordGroup?.setMessage("Keybind capture is unavailable.")
            return
        }
        chordChip.setCapturing(true)
        chordGroup?.setMessage(nil)
        capturer.beginCapture { [weak self] event in self?.handleCaptureEvent(event) }
    }

    private func handleCaptureEvent(_ event: NSEvent) {
        if event.type == .flagsChanged { return }  // modifier held, no key yet
        switch KeyboardFocus.key(for: event) {
        case .escape: endCapture(); return  // cancel — keep the current chord
        case .delete: endCapture(); clearChord(); return  // Backspace → clear
        default: break
        }
        guard let chord = Chord(event: event) else { return }  // unmappable key — keep waiting
        guard chord.command || chord.shift || chord.option || chord.control else {
            chordGroup?.setMessage("Add at least one modifier (⌘ ⇧ ⌥ ⌃).")
            return  // stay armed
        }
        capturedChord = chord
        endCapture()
        chordChip.render(shortcut: chord.displayGlyph)
        chordGroup?.setMessage(nil)
        refreshValidity()
    }

    private func endCapture() {
        capturer?.endCapture()
        chordChip.setCapturing(false)
    }

    private func clearChord() {
        capturedChord = nil
        chordChip.render(shortcut: "")
        refreshValidity()
    }

    // MARK: keyboard focus ring

    /// The vertical navigation order (Up/Down), top to bottom. Height is reached from Width with
    /// Right, and Cancel from Submit with Left — neither is its own vertical stop.
    private func verticalStops() -> [NSView] {
        [
            idField.field, titleField.field, iconPicker, chordChip, commandField.field,
            widthField.field, gitSegment, submitButton,
        ]
    }

    private func moveVertical(_ delta: Int) {
        let stops = verticalStops()
        let anchor = currentVerticalAnchor(in: stops).flatMap { anchor in stops.firstIndex { $0 === anchor } }
        guard let next = KeyboardFocus.step(from: anchor, delta: delta, count: stops.count) else { return }
        window?.makeFirstResponder(stops[next])
    }

    /// The vertical stop representing the current focus — the focused stop itself, or the row anchor
    /// when focus is on Height (→ Width) or Cancel (→ Submit).
    private func currentVerticalAnchor(in stops: [NSView]) -> NSView? {
        if let direct = stops.first(where: isFocused) { return direct }
        if isFocused(heightField.field) { return widthField.field }
        if isFocused(cancelButton) { return submitButton }
        return nil
    }

    private func isFocused(_ view: NSView) -> Bool { KeyboardFocus.isFocused(view, in: window) }

    private func focus(_ view: NSView?) {
        guard let view else { return }
        window?.makeFirstResponder(view)
    }

    private func wireField(_ box: FieldBox) {
        box.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        box.onArrowDown = { [weak self] in self?.moveVertical(1) }
        box.onEsc = { [weak self] in self?.onCancel() }
        box.onSubmit = { [weak self] in self?.submit() }
    }

    private func wireSegment(_ segment: SegmentedControl) {
        segment.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        segment.onArrowDown = { [weak self] in self?.moveVertical(1) }
        segment.onEsc = { [weak self] in self?.onCancel() }
    }

    // MARK: submit + validation

    private func submit() {
        if let firstInvalid = validate(includeRequired: true) {
            window?.makeFirstResponder(firstInvalid)
            return
        }
        guard let float = buildFloat() else { return }
        onSubmit(float)
    }

    private func buildFloat() -> ToolFloat? {
        let id = idField.text.trimmingCharacters(in: .whitespaces)
        let command = commandField.text.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !command.isEmpty, let chord = capturedChord else { return nil }
        let title = titleField.text.trimmingCharacters(in: .whitespaces)
        return ToolFloat(
            id: id,
            title: title.isEmpty ? ToolFloatParser.defaultTitle(forID: id) : title,
            icon: iconPicker.selected,
            command: command,
            widthFraction: fraction(widthField),
            heightFraction: fraction(heightField),
            requiresGitRepo: gitSegment.selectedIndex == 1,
            emptyGuard: editingFloat?.emptyGuard,  // not editable here; preserve (nil today)
            toggle: chord)
    }

    /// Update every field's inline message and return the first offending field to focus (nil when
    /// submittable). `includeRequired` gates the mandatory-but-empty checks: false for the live pass
    /// (don't flag an untouched field), true on a submit attempt.
    @discardableResult
    private func validate(includeRequired: Bool) -> NSView? {
        var firstInvalid: NSView?
        func flag(_ group: LabeledField?, field: NSView, _ message: String?) {
            group?.setMessage(message)
            if message != nil, firstInvalid == nil { firstInvalid = field }
        }

        let id = idField.text.trimmingCharacters(in: .whitespaces)
        var idMessage: String?
        if !id.isEmpty, id.contains(where: { $0.isWhitespace || "\"#".contains($0) }) {
            idMessage = "Can’t contain spaces, \" or #."
        } else if !id.isEmpty, existingIDs.contains(id) {
            idMessage = "A tool float with this id already exists."
        } else if includeRequired, id.isEmpty {
            idMessage = "Enter an id."
        }
        flag(idGroup, field: idField.field, idMessage)

        let command = commandField.text.trimmingCharacters(in: .whitespaces)
        var commandMessage: String?
        if command.contains("\"") {
            commandMessage = "Can’t contain a \" character."  // the grammar has no escape
        } else if includeRequired, command.isEmpty {
            commandMessage = "Enter a command."
        }
        flag(commandGroup, field: commandField.field, commandMessage)

        if includeRequired, capturedChord == nil {
            flag(chordGroup, field: chordChip, "Set a shortcut (needs ⌘ ⇧ ⌥ or ⌃).")
        } else {
            chordGroup?.setMessage(nil)
        }

        let sizeField = firstInvalidSizeField()
        sizeGroup?.setMessage(sizeField == nil ? nil : "Enter a number from 0.2 to 1.0.")
        if let sizeField, firstInvalid == nil { firstInvalid = sizeField }

        return firstInvalid
    }

    /// The first of Width / Height carrying a non-empty, non-fractional value — a blank field is
    /// valid (it falls back to the 0.85 default).
    private func firstInvalidSizeField() -> NSView? {
        for box in [widthField, heightField] {
            let text = box.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            guard let value = Double(text), (0.2...1.0).contains(value) else { return box.field }
        }
        return nil
    }

    private func refreshValidity() { validate(includeRequired: false) }

    /// A width/height field's fraction: its parsed value clamped to 0.2…1.0, or the 0.85 default when
    /// blank. Invalid text never reaches here (validation blocks submit first).
    private func fraction(_ box: FieldBox) -> CGFloat {
        let text = box.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let value = Double(text) else { return ToolFloatParser.defaultFraction }
        return CGFloat(min(max(value, 0.2), 1.0))
    }

    // MARK: layout helpers

    /// A caption retained in `captions` so `reapplyTheme()` can reach it after a theme swap.
    private func caption(_ text: String, required: Bool) -> FieldCaption {
        let field = FieldCaption(text, required: required)
        captions.append(field)
        return field
    }

    private static func fractionText(_ value: CGFloat) -> String { String(format: "%g", Double(value)) }

    private static func hStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private static func vStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
}
