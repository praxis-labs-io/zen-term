import AppKit

final class ToolFloatFormOverlay: NSView, ModalOverlay {
    private let editingFloat: ToolFloat?
    private let existingIDs: Set<String>
    private let capturer: KeybindCapturing?
    private let onSubmit: (ToolFloat) -> Void
    private let onCancel: () -> Void
    private let onDelete: (() -> Void)?

    private let card = CardView()
    private var footerDivider: ThemeReapplying?
    private var dismiss = DismissGate()
    private let header = NSTextField(labelWithString: "")

    private let titleField = FieldBox(placeholder: "Open GitDash")
    private var iconPicker: IconPickerField!
    private let chordChip = KeybindChip()
    private let commandField = FieldBox(placeholder: "npm run dev")
    private let widthField = FieldBox(placeholder: "0.85")
    private let heightField = FieldBox(placeholder: "0.85")
    private let gitSegment = SegmentedControl(options: ["Any folder", "Git repos only"], selectedIndex: 0) { _ in }
    private static let persistOptions: [(mode: ToolFloat.Persistence, title: String)] = [
        (.ephemeral, "Fresh each time"), (.directory, "Per directory"), (.window, "Per window"),
    ]
    private let persistSegment = SegmentedControl(
        options: persistOptions.map(\.title), selectedIndex: 0
    ) { _ in }
    private let toolbarSegment = SegmentedControl(options: ["Shown", "Hidden"], selectedIndex: 0) { _ in }
    private let dirPicker = DirectoryPickerField(placeholder: "Type a path, or Choose")

    private var titleGroup: LabeledField?
    private var iconGroup: LabeledField?
    private var chordGroup: LabeledField?
    private var commandGroup: LabeledField?
    private var dirGroup: LabeledField?
    private var sizeGroup: LabeledField?

    private var captions: [FieldCaption] = []

    private var capturedChord: Chord?
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
            card.heightAnchor.constraint(lessThanOrEqualToConstant: FormCard.maxHeight),

            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        prefill()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func focusInitialResponder() { window?.makeFirstResponder(titleField.field) }

    func animateIn() {
        superview?.layoutSubtreeIfNeeded()
        Motion.springScaleFade(card, appearing: true)
    }

    func animateOut(completion: @escaping () -> Void) {
        guard dismiss.begin() else { return }
        captureCloseTimer?.cancel()
        capturer?.endCapture()
        hideHint()
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        dismiss.isDismissing ? nil : super.hitTest(point)
    }

    /// Esc is claimed here because a focused text field's editor consumes it before `keyDown`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ModalEscape.handle(
            event, in: window, dismissing: dismiss.isDismissing, close: { self.onCancel() }
        ) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Recolors in place, because a rebuild would lose typed values.
    func reapplyTheme() {
        CardChrome.reapplyTheme(to: card)
        header.textColor = Theme.current.chrome.foreground.nsColor
        footerDivider?.reapplyTheme()

        let controls: [ThemeReapplying] = [
            titleField, commandField, dirPicker, widthField, heightField, gitSegment,
            persistSegment, toolbarSegment, cancelButton, submitButton, deleteButton,
        ]
        controls.forEach { $0.reapplyTheme() }
        chordChip.reapplyTheme()
        iconPicker.reapplyTheme()
        for group in [titleGroup, iconGroup, chordGroup, commandGroup, dirGroup, sizeGroup] {
            group?.reapplyTheme()
        }
        captions.forEach { $0.reapplyTheme() }
    }

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
        chordChip.onRemove = { [weak self] in self?.clearChord() }
        chordChip.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        chordChip.onArrowDown = { [weak self] in self?.moveVertical(1) }
        chordChip.onTab = { [weak self] in self?.moveTab(1) }
        chordChip.onBacktab = { [weak self] in self?.moveTab(-1) }
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

        for box in [widthField, heightField] { wireField(box) }
        widthField.onChange = { [weak self] in self?.refreshValidity() }
        heightField.onChange = { [weak self] in self?.refreshValidity() }
        widthField.onArrowRight = { [weak self] in self?.focus(self?.heightField.field) }
        heightField.onArrowLeft = { [weak self] in self?.focus(self?.widthField.field) }
        widthField.onTab = { [weak self] in self?.focus(self?.heightField.field) }
        heightField.onTab = { [weak self] in self?.moveTab(1) }
        heightField.onBacktab = { [weak self] in self?.focus(self?.widthField.field) }
        let times = NSTextField(labelWithString: "×")
        times.font = .systemFont(ofSize: 13)
        times.textColor = Theme.current.chrome.ink(.muted)
        times.setContentHuggingPriority(.required, for: .horizontal)
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

        wireSegment(toolbarSegment)
        let toolbarGroup = Self.vStack([caption("TOOLBAR BUTTON", required: false), toolbarSegment], spacing: 6)

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
        submitButton.onTab = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onBacktab = { [weak self] in self?.focus(self?.submitButton) }
        if onDelete != nil {
            cancelButton.onTab = { [weak self] in self?.focus(self?.deleteButton) }
            deleteButton.onBacktab = { [weak self] in self?.focus(self?.cancelButton) }
        } else {
            cancelButton.onTab = { [weak self] in self?.moveTab(1) }
        }
        let footer = Self.hStack(footerViews, spacing: 8)

        let built = FormCard.content(
            rows: [
                header, titleGroup, iconGroup, chordGroup, commandGroup, dirGroup, sizeGroup,
                gitGroup, persistGroup, toolbarGroup,
            ], footer: footer, spacing: 12)
        footerDivider = built.divider
        return built.view
    }

    /// Seeds only a chord capture would accept, or Save writes back a `key:` the load refused.
    private func prefill() {
        chordChip.render(shortcut: "")
        guard let float = editingFloat else { return }
        titleField.setText(float.title)
        if MenuShortcuts.owner(of: float.toggle) == nil, chordConflict(float.toggle) == nil {
            capturedChord = float.toggle
            chordChip.render(shortcut: float.toggle.displayGlyph)
        }
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
            persistSegment.setSelection(index)
        }
        toolbarSegment.setSelection(float.showsInToolbar ? 0 : 1)
    }

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

    /// Refuses menu chords itself: the live keymap `chordConflict` asks never contains them.
    private func handleCaptureEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            hintBubble?.setPreview(Chord.modifierGlyph(event.modifierFlags))
            return
        }
        switch KeyboardFocus.key(for: event) {
        case .escape: endCapture(); renderChord(); return
        case .delete: endCapture(); clearChord(); return
        default: break
        }
        guard let chord = Chord(event: event) else { return }
        hintBubble?.setPreview(chord.displayGlyph)
        hintBubble?.clearError()
        guard chord.command || chord.shift || chord.option || chord.control else {
            hintBubble?.showError("Add at least one modifier (⌘ ⇧ ⌥ ⌃).")
            positionHint()
            return
        }
        if let menuItem = MenuShortcuts.owner(of: chord) {
            hintBubble?.showError("\(chord.displayGlyph) is the \(menuItem) menu shortcut.")
            positionHint()
            return
        }
        if let conflict = chordConflict(chord) {
            hintBubble?.showError(conflict)
            positionHint()
            return
        }
        commit(chord)
    }

    private func chordConflict(_ chord: Chord) -> String? {
        let ownAction: KeyInterceptor.ReservedChord? = editingFloat.map { .toggleToolFloat($0.id) }
        guard let owner = GeneralConfig.current.keymap[chord], owner != ownAction else { return nil }
        return "That shortcut is already in use."
    }

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

    private func showHint() {
        hideHint()
        let backdrop = BackdropView { [weak self] in self?.cancelCapture() }
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
        hintBackdrop = backdrop
        let bubble = KeybindHintBubble()
        bubble.translatesAutoresizingMaskIntoConstraints = true
        addSubview(bubble)
        hintBubble = bubble
        positionHint()
    }

    private func cancelCapture() {
        endCapture()
        renderChord()
    }

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

    private func verticalStops() -> [NSView] {
        [
            titleField.field, iconPicker, chordChip, commandField.field,
            dirPicker.field.field, widthField.field, gitSegment, persistSegment, toolbarSegment,
            submitButton,
        ]
    }

    private func moveVertical(_ delta: Int) { move(delta, wrap: false) }

    private func moveTab(_ delta: Int) { move(delta, wrap: true) }

    private func move(_ delta: Int, wrap: Bool) {
        let stops = verticalStops()
        let anchor = currentVerticalAnchor(in: stops).flatMap { anchor in stops.firstIndex { $0 === anchor } }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta, wrap: wrap) {
            FormCard.revealTarget(for: $0)
        }
    }

    private func currentVerticalAnchor(in stops: [NSView]) -> NSView? {
        if let direct = stops.first(where: isFocused) { return direct }
        if isFocused(heightField.field) { return widthField.field }
        if isFocused(dirPicker.chooseButton) { return dirPicker.field.field }
        if isFocused(cancelButton) || isFocused(deleteButton) { return submitButton }
        return nil
    }

    private func isFocused(_ view: NSView) -> Bool { KeyboardFocus.isFocused(view, in: window) }

    private func focus(_ view: NSView?) {
        guard let view else { return }
        window?.makeFirstResponder(view)
    }

    /// Height is not wired here: it isn't a vertical stop, so `moveVertical` would skip it.
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
            toggle: chord,
            showsInToolbar: toolbarSegment.selectedIndex == 0)
    }

    private static func nextOrder() -> Int {
        (GeneralConfig.current.floats.map(\.order).max() ?? 0) + 1
    }

    /// The float grammar has no quote escape, so a `"` can't round-trip.
    @discardableResult
    private func validate(includeRequired: Bool) -> NSView? {
        var firstInvalid: NSView?
        func flag(_ group: LabeledField?, field: NSView, _ message: String?) {
            group?.setMessage(message)
            if message != nil, firstInvalid == nil { firstInvalid = field }
        }

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
            commandMessage = "Can't contain a \" character."
        } else if includeRequired, command.isEmpty {
            commandMessage = "Enter a command."
        }
        flag(commandGroup, field: commandField.field, commandMessage)

        let dirText = dirPicker.text.trimmingCharacters(in: .whitespaces)
        var dirMessage: String?
        if dirText.contains("\"") {
            dirMessage = "Can't contain a \" character."
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

    private func fraction(_ box: FieldBox) -> CGFloat {
        let text = box.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let value = Double(text) else { return ToolFloatParser.defaultFraction }
        return ToolFloatParser.clampedFraction(value)
    }

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
