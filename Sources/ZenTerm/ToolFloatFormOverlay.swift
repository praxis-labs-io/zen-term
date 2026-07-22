import AppKit

/// The add / edit form for a tool float, opened from the Settings → Tools section. It collects a
/// float's fields — title, icon, shortcut, command, size, and a git-only toggle — builds a
/// `ToolFloat`, and hands it to `onSubmit` (the host writes it via `ConfigWriter` + reloads, so the
/// dock button, ⌘P entry, and its keybind appear with no restart). A `ModalOverlay` like the
/// palettes and `AddWorkspaceOverlay`, which it mirrors.
///
/// There is no id field: a float's id is `slug(title)`, so the title is the only name the user gives
/// it (ZEN-145). `existingIDs` is therefore a set of slugs — the form rejects a title that collides
/// with one, which is what keeps the config's last-wins rule from ever silently eating a float.
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
    /// Non-nil only when editing — its presence shows the Delete button.
    private let onDelete: (() -> Void)?

    private let card = CardView()
    private var dismiss = DismissGate()
    /// Retained (not a throwaway init-local) so `reapplyTheme()` can recolor it in place.
    private let header = NSTextField(labelWithString: "")

    private let titleField = FieldBox(placeholder: "Open GitDash")
    private var iconPicker: IconPickerField!
    private let chordChip = KeybindChip()
    private let commandField = FieldBox(placeholder: "npm run dev")
    private let widthField = FieldBox(placeholder: "0.85")
    private let heightField = FieldBox(placeholder: "0.85")
    private let gitSegment = SegmentedControl(options: ["Any folder", "Git repos only"], selectedIndex: 0) { _ in }
    /// Segment index ↔ `Persistence` ↔ title, all derived from this one array so the mapping (and the
    /// segment count) can never drift out of sync — a titles array of a different length than the
    /// modes would otherwise crash on submit (index out of range) or leave a mode unselectable.
    private static let persistOptions: [(mode: ToolFloat.Persistence, title: String)] = [
        (.ephemeral, "Fresh each time"), (.directory, "Per directory"), (.window, "Per window"),
    ]
    private let persistSegment = SegmentedControl(
        options: persistOptions.map(\.title), selectedIndex: 0
    ) { _ in }
    private let dirPicker = DirectoryPickerField(placeholder: "Type a path, or Choose")

    private var titleGroup: LabeledField?
    private var iconGroup: LabeledField?
    private var chordGroup: LabeledField?
    private var commandGroup: LabeledField?
    private var dirGroup: LabeledField?
    private var sizeGroup: LabeledField?

    /// Captions built directly into a stack (not wrapped by a `LabeledField`, which retains its own).
    /// Retained so `reapplyTheme()` can reach them after a live theme swap while the form is open.
    private var captions: [FieldCaption] = []

    /// The chord captured for the shortcut, or nil until one is recorded. The float's single source
    /// of truth for its key — rendered into the chip and written as the `key:` token.
    private var capturedChord: Chord?
    /// The shared keybind-capture popover (same as the Keybinds section) + its modal backdrop and the
    /// timer that closes it after a successful capture.
    private var hintBubble: KeybindHintBubble?
    private var hintBackdrop: NSView?
    private var captureCloseTimer: DispatchWorkItem?

    private let cancelButton = AppButton(title: "Cancel", variant: .secondary)
    private let submitButton = AppButton(
        title: "", variant: .primary, keyEquivalent: "\r", keyEquivalentModifierMask: .command)
    private let deleteButton = AppButton(title: "Delete", variant: .destructive)

    init(
        editing: ToolFloat?, existingIDs: Set<String>, capturer: KeybindCapturing?, background: NSColor,
        onSubmit: @escaping (ToolFloat) -> Void, onCancel: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.editingFloat = editing
        self.existingIDs = existingIDs
        self.capturer = capturer
        self.onDelete = onDelete
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

    func focusInitialResponder() { window?.makeFirstResponder(titleField.field) }

    func animateIn() {
        superview?.layoutSubtreeIfNeeded()  // resolve the card's frame before scaling about its center
        Motion.springScaleFade(card, appearing: true)
    }

    func animateOut(completion: @escaping () -> Void) {
        guard dismiss.begin() else { return }
        captureCloseTimer?.cancel()
        capturer?.endCapture()  // never leave a capture handler armed after the form closes
        hideHint()
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        dismiss.isDismissing ? nil : super.hitTest(point)
    }

    /// The form's Esc fallback. A bare Esc reaches the focused control's `keyDown` first, so an open
    /// icon grid closes itself there (`IconPickerField.keyDown`) and a typed-in form survives
    /// untouched — this pass never runs while the grid is up (ZEN-5). Claimed in
    /// `performKeyEquivalent`, not a card-root `keyDown`, so it also catches Esc from a focused text
    /// field, whose field editor consumes it (`cancelOperation`) before it could bubble as a keyDown
    /// — one Esc owner per card, so a stray Esc can't discard a filled-in form (ZEN-77). The Cancel
    /// button carries no Esc key equivalent; this pass is the owner.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ModalEscape.handle(
            event, in: window, dismissing: dismiss.isDismissing, close: { self.onCancel() }
        ) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Re-apply the form's theme-dependent colors after a live theme change, IN PLACE — this form
    /// holds uncommitted typed values a rebuild would lose, so nothing here is rebuilt, only
    /// recolored. Every leaf control conforms to `ThemeReapplying`, so they recolor as one group.
    func reapplyTheme() {
        CardChrome.reapplyTheme(to: card)
        header.textColor = Theme.current.chrome.foreground.nsColor

        let controls: [ThemeReapplying] = [
            titleField, commandField, dirPicker, widthField, heightField, gitSegment,
            persistSegment, cancelButton, submitButton, deleteButton,
        ]
        controls.forEach { $0.reapplyTheme() }
        chordChip.reapplyTheme()
        iconPicker.reapplyTheme()
        for group in [titleGroup, iconGroup, chordGroup, commandGroup, dirGroup, sizeGroup] {
            group?.reapplyTheme()
        }
        captions.forEach { $0.reapplyTheme() }
    }

    // MARK: content

    private func buildContent() -> NSStackView {
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = Theme.current.chrome.foreground.nsColor
        header.stringValue = editingFloat == nil ? "New Tool Float" : "Edit Tool Float"

        wireField(titleField)
        titleField.onChange = { [weak self] in self?.refreshValidity() }
        let titleGroup = LabeledField(caption: caption("TITLE", required: true), control: titleField)
        self.titleGroup = titleGroup

        let picker = IconPickerField(selected: editingFloat?.icon ?? IconCatalog.defaultSymbol)
        picker.onChange = { [weak self] _ in self?.refreshValidity() }
        picker.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        picker.onArrowDown = { [weak self] in self?.moveVertical(1) }
        picker.onTab = { [weak self] in self?.moveTab(1) }
        picker.onBacktab = { [weak self] in self?.moveTab(-1) }
        iconPicker = picker
        let iconGroup = LabeledField(caption: caption("ICON", required: false), control: picker)
        self.iconGroup = iconGroup

        chordChip.onActivate = { [weak self] in self?.beginCapture() }
        chordChip.onReset = { [weak self] in self?.clearChord() }
        chordChip.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        chordChip.onArrowDown = { [weak self] in self?.moveVertical(1) }
        chordChip.onTab = { [weak self] in self?.moveTab(1) }
        chordChip.onBacktab = { [weak self] in self?.moveTab(-1) }
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

        wireField(dirPicker.field)
        dirPicker.field.onChange = { [weak self] in self?.refreshValidity() }
        dirPicker.onPicked = { [weak self] _ in self?.refreshValidity() }
        dirPicker.wireNav(
            onVertical: { [weak self] in self?.moveVertical($0) },
            onTabForward: { [weak self] in self?.moveTab(1) })
        let dirGroup = LabeledField(caption: caption("DIRECTORY", required: false), control: dirPicker)
        self.dirGroup = dirGroup

        // Width × Height share one row (a fraction of the tile). Width is the row's vertical stop;
        // Height is reached with Right (like an env row's value box).
        for box in [widthField, heightField] { wireField(box) }
        widthField.onChange = { [weak self] in self?.refreshValidity() }
        heightField.onChange = { [weak self] in self?.refreshValidity() }
        widthField.onArrowRight = { [weak self] in self?.focus(self?.heightField.field) }
        heightField.onArrowLeft = { [weak self] in self?.focus(self?.widthField.field) }
        // Width × Height are one vertical stop, so Tab walks the pair in reading order — Width →
        // Height → the next stop — instead of `moveVertical` skipping Height (which isn't a stop)
        // and leaving it reachable only by Right.
        widthField.onTab = { [weak self] in self?.focus(self?.heightField.field) }
        heightField.onTab = { [weak self] in self?.moveTab(1) }
        heightField.onBacktab = { [weak self] in self?.focus(self?.widthField.field) }
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

        wireSegment(persistSegment)
        let persistGroup = Self.vStack([caption("KEEP RUNNING", required: false), persistSegment], spacing: 6)

        cancelButton.onTap = { [weak self] in self?.onCancel() }
        submitButton.setTitle(editingFloat == nil ? "Add Tool Float" : "Save")
        submitButton.onTap = { [weak self] in self?.submit() }
        for button in [cancelButton, submitButton] {
            button.isKeyboardFocusable = true
            button.onArrowUp = { [weak self] in self?.moveVertical(-1) }
            button.onArrowDown = { [weak self] in self?.moveVertical(1) }
            button.onTab = { [weak self] in self?.moveTab(1) }
            button.onBacktab = { [weak self] in self?.moveTab(-1) }
        }
        submitButton.onArrowLeft = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onArrowRight = { [weak self] in self?.focus(self?.submitButton) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var footerViews: [NSView] = [spacer, cancelButton, submitButton]
        if onDelete != nil {
            // Delete sits far left, split from Cancel/Save; Left from Save walks Save → Cancel →
            // Delete (a destructive action kept a deliberate step off the primary path).
            deleteButton.isKeyboardFocusable = true
            deleteButton.onTap = { [weak self] in self?.onDelete?() }
            deleteButton.onArrowUp = { [weak self] in self?.moveVertical(-1) }
            deleteButton.onArrowDown = { [weak self] in self?.moveVertical(1) }
            deleteButton.onTab = { [weak self] in self?.moveTab(1) }
            deleteButton.onBacktab = { [weak self] in self?.moveTab(-1) }
            deleteButton.onArrowRight = { [weak self] in self?.focus(self?.cancelButton) }
            cancelButton.onArrowLeft = { [weak self] in self?.focus(self?.deleteButton) }
            footerViews = [deleteButton, spacer, cancelButton, submitButton]
        }
        // Tab walks the footer in place so Cancel (and Delete when editing) are Tab-reachable, not
        // Left/Right-only: Submit → Cancel → Delete, mirroring the Left-arrow order. Forward Tab off
        // the last button wraps to the top; Shift-Tab off Submit leaves the footer upward.
        submitButton.onTab = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onBacktab = { [weak self] in self?.focus(self?.submitButton) }
        if onDelete != nil {
            cancelButton.onTab = { [weak self] in self?.focus(self?.deleteButton) }
            deleteButton.onBacktab = { [weak self] in self?.focus(self?.cancelButton) }
        } else {
            cancelButton.onTab = { [weak self] in self?.moveTab(1) }
        }
        let footer = Self.hStack(footerViews, spacing: 8)

        let content = NSStackView(views: [
            header, titleGroup, iconGroup, chordGroup, commandGroup, dirGroup, sizeGroup,
            gitGroup, persistGroup, footer,
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
        titleField.setText(float.title)
        capturedChord = float.toggle
        chordChip.render(shortcut: float.toggle.displayGlyph)
        commandField.setText(float.command)
        if float.widthFraction != ToolFloatParser.defaultFraction {
            widthField.setText(ToolFloatParser.fractionText(float.widthFraction))
        }
        if float.heightFraction != ToolFloatParser.defaultFraction {
            heightField.setText(ToolFloatParser.fractionText(float.heightFraction))
        }
        gitSegment.setSelection(float.requiresGitRepo ? 1 : 0)
        if let dir = float.dir { dirPicker.setText(PathDisplay.abbreviatingHome(dir.path)) }
        if let index = Self.persistOptions.firstIndex(where: { $0.mode == float.persist }) {
            persistSegment.setSelection(index)  // programmatic sync must not fire onChange
        }
    }

    // MARK: chord capture

    /// Arm the shortcut chip and float the shared keybind-capture popover (`KeybindHintBubble`) beside
    /// it — the same UX as the Keybinds section. The next chord records through the interceptor (so an
    /// already-bound chord isn't pre-empted); an invalid chord (no modifier) shows an error in the
    /// popover and stays armed, a valid one commits with a success line and closes. A backdrop makes
    /// it modal: an outside click cancels. Esc cancels; Backspace clears.
    private func beginCapture() {
        guard let capturer else {
            chordGroup?.setMessage("Shortcut capture is unavailable.")
            return
        }
        chordGroup?.setMessage(nil)
        chordChip.setCapturing(true)
        showHint()
        capturer.beginCapture { [weak self] event in self?.handleCaptureEvent(event) }
    }

    private func handleCaptureEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {  // live modifier preview (⌘, ⌘⇧, …) before a key lands
            hintBubble?.setPreview(Chord.modifierGlyph(event.modifierFlags))
            return
        }
        switch KeyboardFocus.key(for: event) {
        case .escape: endCapture(); renderChord(); return  // cancel — keep the current chord
        case .delete: endCapture(); clearChord(); return  // Backspace → clear
        default: break
        }
        guard let chord = Chord(event: event) else { return }  // unmappable key — keep waiting
        hintBubble?.setPreview(chord.displayGlyph)
        hintBubble?.clearError()
        guard chord.command || chord.shift || chord.option || chord.control else {
            hintBubble?.showError("Add at least one modifier (⌘ ⇧ ⌥ ⌃).")
            positionHint()
            return  // stay armed
        }
        if let conflict = chordConflict(chord) {
            hintBubble?.showError(conflict)
            positionHint()
            return  // stay armed
        }
        commit(chord)
    }

    /// Reject a chord already bound to another action or float (mirrors the Keybinds section's
    /// block-on-conflict) so a new float can't silently shadow an existing shortcut. The float being
    /// edited keeps its own current chord.
    private func chordConflict(_ chord: Chord) -> String? {
        let ownAction: KeyInterceptor.ReservedChord? = editingFloat.map { .toggleToolFloat($0.id) }
        guard let owner = GeneralConfig.current.keymap[chord], owner != ownAction else { return nil }
        return "That shortcut is already in use."
    }

    /// Apply a validated chord: flash a success line in the popover, then close after a short beat.
    private func commit(_ chord: Chord) {
        capturedChord = chord
        capturer?.endCapture()
        chordChip.render(shortcut: chord.displayGlyph)
        hintBubble?.setPreview(chord.displayGlyph)
        hintBubble?.showSuccess("Shortcut saved.")
        positionHint()
        let close = DispatchWorkItem { [weak self] in
            self?.hideHint()
            self?.chordChip.setCapturing(false)
        }
        captureCloseTimer = close
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: close)
        refreshValidity()
    }

    /// End an armed capture immediately (Esc / Delete / outside click); the caller restores or clears.
    private func endCapture() {
        captureCloseTimer?.cancel()
        capturer?.endCapture()
        hideHint()
        chordChip.setCapturing(false)
    }

    private func renderChord() { chordChip.render(shortcut: capturedChord?.displayGlyph ?? "") }

    private func clearChord() {
        capturedChord = nil
        renderChord()
        refreshValidity()
    }

    // MARK: capture popover

    /// Float the shared `KeybindHintBubble` over the form, just below the shortcut chip, behind a
    /// transparent modal backdrop that cancels on an outside click. Mirrors the Keybinds section.
    private func showHint() {
        hideHint()
        let backdrop = BackdropView { [weak self] in self?.cancelCapture() }
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
        hintBackdrop = backdrop
        let bubble = KeybindHintBubble()
        bubble.translatesAutoresizingMaskIntoConstraints = true
        addSubview(bubble)  // above the backdrop
        hintBubble = bubble
        positionHint()
    }

    private func cancelCapture() {
        endCapture()
        renderChord()
    }

    /// (Re)place the bubble just below the chip — re-run when its height changes (an error/success
    /// line replacing the instructions grows it). `self` isn't flipped: below the chip = a smaller y;
    /// if that runs off the top, flip below the chip.
    private func positionHint() {
        guard let bubble = hintBubble else { return }
        bubble.layoutSubtreeIfNeeded()
        let size = bubble.fittingSize
        let chipRect = chordChip.convert(chordChip.bounds, to: self)
        let x = max(8, min(chipRect.midX - size.width / 2, bounds.width - size.width - 8))
        let maxY = max(8, bounds.height - size.height - 8)
        var y = chipRect.minY - size.height - 6
        if y < 8 { y = chipRect.maxY + 6 }
        y = max(8, min(y, maxY))
        bubble.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func hideHint() {
        hintBubble?.removeFromSuperview()
        hintBubble = nil
        hintBackdrop?.removeFromSuperview()
        hintBackdrop = nil
    }

    // MARK: keyboard focus ring

    /// The vertical navigation order (Up/Down), top to bottom. Height is reached from Width with
    /// Right, and Cancel from Submit with Left — neither is its own vertical stop.
    private func verticalStops() -> [NSView] {
        [
            titleField.field, iconPicker, chordChip, commandField.field,
            dirPicker.field.field, widthField.field, gitSegment, persistSegment, submitButton,
        ]
    }

    private func moveVertical(_ delta: Int) {
        let stops = verticalStops()
        let anchor = currentVerticalAnchor(in: stops).flatMap { anchor in stops.firstIndex { $0 === anchor } }
        guard let next = KeyboardFocus.step(from: anchor, delta: delta, count: stops.count) else { return }
        window?.makeFirstResponder(stops[next])
    }

    /// Tab traversal: wraps at the ends where the arrows clamp, so a Tab loop never dies on the last
    /// stop. Matches the Settings card, so the same key behaves the same way in every card.
    private func moveTab(_ delta: Int) {
        let stops = verticalStops()
        let anchor = currentVerticalAnchor(in: stops).flatMap { anchor in stops.firstIndex { $0 === anchor } }
        guard let next = KeyboardFocus.step(from: anchor, delta: delta, count: stops.count, wrap: true)
        else { return }
        window?.makeFirstResponder(stops[next])
    }

    /// The vertical stop representing the current focus — the focused stop itself, or the row anchor
    /// when focus is on Height (→ Width) or Cancel (→ Submit).
    private func currentVerticalAnchor(in stops: [NSView]) -> NSView? {
        if let direct = stops.first(where: isFocused) { return direct }
        if isFocused(heightField.field) { return widthField.field }
        // The Choose button shares the directory field's vertical stop; it's reached with Right.
        if isFocused(dirPicker.chooseButton) { return dirPicker.field.field }
        if isFocused(cancelButton) || isFocused(deleteButton) { return submitButton }
        return nil
    }

    private func isFocused(_ view: NSView) -> Bool { KeyboardFocus.isFocused(view, in: window) }

    private func focus(_ view: NSView?) {
        guard let view else { return }
        window?.makeFirstResponder(view)
    }

    /// Tab/Shift-Tab traverse the form's own stops, exactly like Down/Up. Without this the field
    /// editor leaked Tab to AppKit's default key-view loop while Tab on the form's buttons was
    /// consumed as advance/retreat — the same key doing two different things in one card.
    ///
    /// Height is deliberately NOT wired here: it isn't a vertical stop (it hangs off Width with
    /// Right), so routing its Tab through `moveVertical` would skip straight past it and leave the
    /// field unreachable by Tab entirely. It gets its own wiring in `buildContent`.
    private func wireField(_ box: FieldBox) {
        box.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        box.onArrowDown = { [weak self] in self?.moveVertical(1) }
        box.onTab = { [weak self] in self?.moveTab(1) }
        box.onBacktab = { [weak self] in self?.moveTab(-1) }
        box.onSubmit = { [weak self] in self?.submit() }
    }

    private func wireSegment(_ segment: SegmentedControl) {
        segment.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        segment.onArrowDown = { [weak self] in self?.moveVertical(1) }
        segment.onTab = { [weak self] in self?.moveTab(1) }
        segment.onBacktab = { [weak self] in self?.moveTab(-1) }
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
        let title = titleField.text.trimmingCharacters(in: .whitespaces)
        let command = commandField.text.trimmingCharacters(in: .whitespaces)
        let id = ToolFloatParser.slug(forTitle: title)
        guard !id.isEmpty, !command.isEmpty, let chord = capturedChord else { return nil }
        let pinnedDir = dirPicker.text.trimmingCharacters(in: .whitespaces)
        return ToolFloat(
            id: id,
            order: editingFloat?.order ?? Self.nextOrder(),
            title: title,
            icon: iconPicker.selected,
            command: command,
            dir: ToolFloatParser.resolveDir(pinnedDir),
            widthFraction: fraction(widthField),
            heightFraction: fraction(heightField),
            requiresGitRepo: gitSegment.selectedIndex == 1,
            persist: Self.persistOptions[persistSegment.selectedIndex].mode,
            toggle: chord)
    }

    /// A new float lands at the end of the dock; editing keeps the float's existing slot. Reads the
    /// live catalog rather than a passed-in value for the same reason `chordConflict` does — the form
    /// is built fresh on every open, so the config it reads is the config it's about to be written to.
    private static func nextOrder() -> Int {
        (GeneralConfig.current.floats.map(\.order).max() ?? 0) + 1
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

        // The title is the float's whole identity now: it names the tool AND slugs to the id that keys
        // its keybind, its live instance, and its config line. So the checks a bare label wouldn't
        // need — a `"` can't round-trip (`serializeFloat` quotes it and the parser has no escape, so
        // it corrupts or drops the float on reload); a title of pure emoji or punctuation slugs to
        // nothing, leaving a float nothing could address; and two titles that slug alike would collide,
        // where the config's last-wins rule silently eats one.
        let title = titleField.text.trimmingCharacters(in: .whitespaces)
        var titleMessage: String?
        if title.contains("\"") {
            titleMessage = "Can't contain a \" character."
        } else if !title.isEmpty, ToolFloatParser.slug(forTitle: title).isEmpty {
            titleMessage = "Needs at least one letter or number."
        } else if !title.isEmpty, existingIDs.contains(ToolFloatParser.slug(forTitle: title)) {
            titleMessage = "A tool float with this title already exists."
        } else if includeRequired, title.isEmpty {
            titleMessage = "Enter a title."
        }
        flag(titleGroup, field: titleField.field, titleMessage)

        let command = commandField.text.trimmingCharacters(in: .whitespaces)
        var commandMessage: String?
        if command.contains("\"") {
            commandMessage = "Can't contain a \" character."  // the grammar has no escape
        } else if includeRequired, command.isEmpty {
            commandMessage = "Enter a command."
        }
        flag(commandGroup, field: commandField.field, commandMessage)

        // Same round-trip constraint as title/command, plus a folder-exists check (mirroring
        // `AddWorkspaceOverlay`'s DIRECTORY field) — an empty field stays valid, since nil means
        // "follow the pane's cwd" rather than a folder that must exist. The exists check runs on
        // submit only (`includeRequired`): it stats the filesystem on the main thread, and a path
        // under a dead network mount can block for seconds — per keystroke that's a beachball.
        let dirText = dirPicker.text.trimmingCharacters(in: .whitespaces)
        var dirMessage: String?
        if dirText.contains("\"") {
            dirMessage = "Can't contain a \" character."  // the grammar has no escape
        } else if includeRequired, let dirURL = ToolFloatParser.resolveDir(dirText),
            !PathDisplay.isDirectory(dirURL)
        {
            dirMessage = "That folder doesn't exist."
        }
        flag(dirGroup, field: dirPicker.field.field, dirMessage)

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

    /// The first of Width / Height carrying a non-empty, out-of-range value — a blank field is valid
    /// (it falls back to the default). Shares the parser's range so the two never disagree.
    private func firstInvalidSizeField() -> NSView? {
        for box in [widthField, heightField] {
            let text = box.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            guard let value = Double(text), ToolFloatParser.fractionRange.contains(CGFloat(value)) else {
                return box.field
            }
        }
        return nil
    }

    private func refreshValidity() { validate(includeRequired: false) }

    /// A width/height field's fraction: its parsed value clamped to the valid range, or the default
    /// when blank. Invalid text never reaches here (validation blocks submit first).
    private func fraction(_ box: FieldBox) -> CGFloat {
        let text = box.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let value = Double(text) else { return ToolFloatParser.defaultFraction }
        return ToolFloatParser.clampedFraction(value)
    }

    // MARK: layout helpers

    /// A caption retained in `captions` so `reapplyTheme()` can reach it after a theme swap.
    private func caption(_ text: String, required: Bool) -> FieldCaption {
        let field = FieldCaption(text, required: required)
        captions.append(field)
        return field
    }

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
