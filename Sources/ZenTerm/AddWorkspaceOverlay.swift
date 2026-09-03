import AppKit

/// The add / edit form card for a workspace, opened from the ⌘P picker's ＋ row (add) and the
/// Settings → Workspaces section (add / edit). It collects a folder, title, layout recipe, and env
/// vars, builds a `Workspace`, and hands it to `onSubmit` — the host writes it to the `workspaces`
/// file (and, from the picker, opens it). A `ModalOverlay` like the palettes (shared card + backdrop
/// + spring), but a multi-field form; mirrors `ToolFloatFormOverlay`, including its Delete button.
///
/// Fully keyboard-driven: Up/Down move between fields, Left/Right pick within a segmented control,
/// Return advances to the next field (opens the folder panel when the empty folder field is
/// focused), ⌘Return submits, Esc cancels. Every input is full width, the focused field/control
/// reads as a muted fill, and each field shows its own validation message beneath it.
final class AddWorkspaceOverlay: NSView, ModalOverlay {
    /// A layout preset; `custom` reveals the raw recipe fields.
    private enum LayoutChoice { case minimal, editorAIShell, custom }

    /// The editor / AI the "Editor + AI + Shell" preset launches, snapshotted at open (from `config`
    /// `editor` / `ai`, falling back to the built-in defaults) so the caption shown and the recipe
    /// stored can't disagree if the config changes while the form is up.
    private let presetEditor: String
    private let presetAI: String

    /// The layout captions, built once from the snapshot. The preset caption names the configured
    /// editor / AI so it stays truthful when the user picks their own tools.
    private lazy var layoutCaptions: [String] = [
        "One shell, drawers closed", "\(presetEditor), \(presetAI), shell", "Set each region yourself",
    ]

    private let editingWorkspace: Workspace?
    private let existingTitles: Set<String>
    private let onSubmit: (Workspace) -> Void
    private let onCancel: () -> Void
    /// Non-nil only when editing — its presence shows the Delete button.
    private let onDelete: (() -> Void)?

    private let card = CardView()
    private var dismiss = DismissGate()
    /// Retained (not a throwaway init-local) so `reapplyTheme()` can recolor it in place.
    private let header = NSTextField(labelWithString: "")

    private let titleField = FieldBox(placeholder: "Workspace name")
    private let folderPicker = DirectoryPickerField(placeholder: "Type a path, or Choose")
    private var titleGroup: LabeledField?
    private var folderGroup: LabeledField?
    private var titleEditedByUser = false

    private let layoutSegment = SegmentedControl(
        options: ["Minimal", "Editor + AI + Shell", "Custom"], selectedIndex: 1
    ) { _ in }
    private let layoutCaption = NSTextField(labelWithString: "")
    private let customDetail = NSStackView()
    private let mainField = FieldBox(placeholder: "blank → plain shell")
    private let rightField = FieldBox(placeholder: "blank → drawer closed")
    private let bottomField = FieldBox(placeholder: "blank → drawer closed")
    private var mainGroup: LabeledField?
    private var rightGroup: LabeledField?
    private var bottomGroup: LabeledField?
    private let focusSegment = SegmentedControl(options: ["Main", "Right", "Bottom"], selectedIndex: 0) { _ in }

    /// Captions built directly into a stack rather than wrapped by a `LabeledField` (which
    /// retains its own caption already) — e.g. LAYOUT/ENVIRONMENT/FOCUS. Retained here so
    /// `reapplyTheme()` can reach them too; otherwise they'd go stranded and stale on a live
    /// theme swap while the form is open. Built via the `caption(_:required:)` instance helper.
    private var captions: [FieldCaption] = []
    private var envRows: [EnvRow] = []
    private let envStack = NSStackView()
    private var excludeRows: [CloneExcludeRow] = []
    private let excludeStack = NSStackView()
    private let envError = NSTextField(labelWithString: "")
    private let addVarButton = AppButton(title: "＋ Add variable", variant: .muted)
    private let addExcludeButton = AppButton(title: "＋ Add path", variant: .muted)
    private let excludeCaption = NSTextField(labelWithString: "")
    private let excludeError = NSTextField(labelWithString: "")
    private let cancelButton = AppButton(title: "Cancel", variant: .secondary)
    private let addButton = AppButton(
        title: "Add Workspace", variant: .primary, keyEquivalent: "\r", keyEquivalentModifierMask: .command)
    private let deleteButton = AppButton(title: "Delete", variant: .destructive)

    init(
        editing: Workspace? = nil, existingTitles: Set<String>, background: NSColor,
        onSubmit: @escaping (Workspace) -> Void, onCancel: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.editingWorkspace = editing
        self.existingTitles = existingTitles
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.onDelete = onDelete
        self.presetEditor = GeneralConfig.current.editor ?? GeneralConfig.defaultEditor
        self.presetAI = GeneralConfig.current.ai ?? GeneralConfig.defaultAI
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

        prefill()  // seed the fields from the edited workspace (a no-op when adding)
        layoutChanged(layoutSegment.selectedIndex)  // seed the caption + custom visibility
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
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        dismiss.isDismissing ? nil : super.hitTest(point)
    }

    /// The form's Esc fallback. This card has no popover host, so Esc always ends here: a focused
    /// button or segmented control lets it bubble to this pass, and a focused text field routes Esc
    /// through its field editor (`cancelOperation`), which never bubbles as a card-root `keyDown`.
    /// Claiming Esc in `performKeyEquivalent` catches both, so the card is the single Esc owner
    /// rather than each control deciding by accident. The Cancel button carries no Esc key
    /// equivalent; this pass is what cancels the form.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ModalEscape.handle(
            event, in: window, dismissing: dismiss.isDismissing, close: { self.onCancel() }
        ) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Re-apply the form's theme-dependent colors after a live theme change, IN PLACE — unlike
    /// the palettes, this form holds uncommitted typed values (fields + dynamic env rows) that a
    /// rebuild would lose, so nothing here is ever rebuilt, only recolored. Every leaf control
    /// conforms to `ThemeReapplying` (Task 6/7), so they're recolored as one group instead of a
    /// type-switch; `EnvRow` and `LabeledField` get their own small `reapplyTheme()` for the same
    /// reason KeybindRow does — a composite that owns otherwise-stranded static labels.
    func reapplyTheme() {
        let chrome = Theme.current.chrome
        CardChrome.reapplyTheme(to: card)
        header.textColor = chrome.foreground.nsColor
        layoutCaption.textColor = chrome.ink(.muted)
        envError.textColor = chrome.destructive.nsColor

        let controls: [ThemeReapplying] = [
            titleField, folderPicker, mainField, rightField, bottomField,
            layoutSegment, focusSegment, addVarButton, addExcludeButton, cancelButton, addButton, deleteButton,
        ]
        controls.forEach { $0.reapplyTheme() }
        envRows.forEach { $0.reapplyTheme() }
        excludeRows.forEach { $0.reapplyTheme() }
        excludeCaption.textColor = chrome.ink(.muted)
        excludeError.textColor = chrome.destructive.nsColor
        for group in [titleGroup, folderGroup, mainGroup, rightGroup, bottomGroup] {
            group?.reapplyTheme()
        }
        captions.forEach { $0.reapplyTheme() }
    }

    // MARK: content

    private func buildContent() -> NSStackView {
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = Theme.current.chrome.foreground.nsColor
        header.stringValue = editingWorkspace == nil ? "New Workspace" : "Edit Workspace"

        wireField(titleField)
        titleField.onChange = { [weak self] in
            self?.titleEditedByUser = true
            self?.refreshValidity()
        }
        let titleGroup = LabeledField(caption: Self.caption("WORKSPACE NAME", required: true), control: titleField)
        self.titleGroup = titleGroup

        wireField(folderPicker.field)
        // Choosing a folder seeds the title from its name until the user has edited the title.
        folderPicker.onPicked = { [weak self] url in
            guard let self else { return }
            if !self.titleEditedByUser { self.titleField.setText(url.lastPathComponent) }
            self.refreshValidity()
        }
        folderPicker.wireNav(
            onVertical: { [weak self] in self?.moveVertical($0) },
            onTabForward: { [weak self] in self?.moveTab(1) })
        let folderGroup = LabeledField(caption: Self.caption("FOLDER", required: true), control: folderPicker)
        self.folderGroup = folderGroup

        layoutSegment.onChange = { [weak self] index in self?.layoutChanged(index) }
        wireSegment(layoutSegment)
        wireSegment(focusSegment)
        layoutCaption.font = .systemFont(ofSize: 11)
        layoutCaption.textColor = Theme.current.chrome.ink(.muted)
        let layoutGroup = Self.vStack(
            [caption("LAYOUT", required: false), layoutSegment, layoutCaption], spacing: 6)

        buildCustomDetail()

        envStack.orientation = .vertical
        envStack.alignment = .leading
        envStack.spacing = 6
        addVarButton.onTap = { [weak self] in self?.addEnvRow() }
        envError.font = .systemFont(ofSize: 11, weight: .medium)
        envError.textColor = Theme.current.chrome.destructive.nsColor
        envError.isHidden = true
        let envControls = Self.vStack([envStack, Self.leadingWrap(addVarButton), envError], spacing: 8)
        let envGroup = Self.vStack([caption("ENVIRONMENT", required: false), envControls], spacing: 6)

        excludeStack.orientation = .vertical
        excludeStack.alignment = .leading
        excludeStack.spacing = 6
        addExcludeButton.onTap = { [weak self] in self?.addExcludeRow() }
        excludeCaption.font = .systemFont(ofSize: 11)
        excludeCaption.textColor = Theme.current.chrome.ink(.muted)
        excludeCaption.stringValue = Self.excludeCaptionText
        excludeError.font = .systemFont(ofSize: 11, weight: .medium)
        excludeError.textColor = Theme.current.chrome.destructive.nsColor
        excludeError.isHidden = true
        let excludeControls = Self.vStack(
            [excludeStack, Self.leadingWrap(addExcludeButton), excludeError, excludeCaption],
            spacing: 8)
        let excludeGroup = Self.vStack(
            [caption("LEAVE OUT OF CLONES", required: false), excludeControls], spacing: 6)

        cancelButton.onTap = { [weak self] in self?.onCancel() }
        addButton.setTitle(editingWorkspace == nil ? "Add Workspace" : "Save")
        addButton.onTap = { [weak self] in self?.submit() }
        for button in [addVarButton, addExcludeButton, cancelButton, addButton] {
            button.isKeyboardFocusable = true
            button.onArrowUp = { [weak self] in self?.moveVertical(-1) }
            button.onArrowDown = { [weak self] in self?.moveVertical(1) }
            button.onTab = { [weak self] in self?.moveTab(1) }
            button.onBacktab = { [weak self] in self?.moveTab(-1) }
        }
        // Add · Cancel are a horizontal pair — Left/Right move between them (matching the layout).
        addButton.onArrowLeft = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onArrowRight = { [weak self] in self?.focus(self?.addButton) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var footerViews: [NSView] = [spacer, cancelButton, addButton]
        if onDelete != nil {
            // Delete sits far left, split from Cancel/Save; Left from Save walks Save → Cancel →
            // Delete (a destructive action kept a deliberate step off the primary path). Mirrors
            // `ToolFloatFormOverlay`.
            deleteButton.isKeyboardFocusable = true
            deleteButton.onTap = { [weak self] in self?.onDelete?() }
            deleteButton.onArrowUp = { [weak self] in self?.moveVertical(-1) }
            deleteButton.onArrowDown = { [weak self] in self?.moveVertical(1) }
            deleteButton.onTab = { [weak self] in self?.moveTab(1) }
            deleteButton.onBacktab = { [weak self] in self?.moveTab(-1) }
            deleteButton.onArrowRight = { [weak self] in self?.focus(self?.cancelButton) }
            cancelButton.onArrowLeft = { [weak self] in self?.focus(self?.deleteButton) }
            footerViews = [deleteButton, spacer, cancelButton, addButton]
        }
        // Tab walks the footer in place so Cancel (and Delete when editing) are Tab-reachable, not
        // Left/Right-only: the primary button (Add Workspace / Save) → Cancel → Delete, mirroring the
        // Left-arrow order. Forward Tab off the last button wraps to the top; Shift-Tab off the
        // primary button leaves the footer upward.
        addButton.onTab = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onBacktab = { [weak self] in self?.focus(self?.addButton) }
        if onDelete != nil {
            cancelButton.onTab = { [weak self] in self?.focus(self?.deleteButton) }
            deleteButton.onBacktab = { [weak self] in self?.focus(self?.cancelButton) }
        } else {
            cancelButton.onTab = { [weak self] in self?.moveTab(1) }
        }
        let footer = Self.hStack(footerViews, spacing: 8)

        let content = NSStackView(views: [
            header, titleGroup, folderGroup, layoutGroup, customDetail, envGroup, excludeGroup, footer,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        // Stretch every row to the inset content width (AppKit stacks have no `.fill` alignment).
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        }
        return content
    }

    private func buildCustomDetail() {
        customDetail.orientation = .vertical
        customDetail.alignment = .leading
        customDetail.spacing = 12
        for box in [mainField, rightField, bottomField] { wireField(box) }
        let mainGroup = LabeledField(caption: Self.caption("MAIN PANE", required: false), control: mainField)
        let rightGroup = LabeledField(caption: Self.caption("RIGHT DRAWER", required: false), control: rightField)
        let bottomGroup = LabeledField(caption: Self.caption("BOTTOM DRAWER", required: false), control: bottomField)
        self.mainGroup = mainGroup
        self.rightGroup = rightGroup
        self.bottomGroup = bottomGroup
        let focusGroup = Self.vStack([caption("FOCUS", required: false), focusSegment], spacing: 6)
        for group in [mainGroup, rightGroup, bottomGroup, focusGroup] as [NSView] {
            customDetail.addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: customDetail.widthAnchor).isActive = true
        }
    }

    // MARK: keyboard focus ring

    /// The vertical navigation order (Up/Down), top to bottom — rebuilt on demand so it reflects
    /// whether the custom fields are shown and how many env rows exist. Each env row contributes a
    /// single stop (its KEY field); its value box and remove button are reached with Left/Right.
    private func verticalStops() -> [NSView] {
        var stops: [NSView] = [titleField.field, folderPicker.field.field, layoutSegment]
        if layoutChoice == .custom {
            stops += [mainField.field, rightField.field, bottomField.field, focusSegment]
        }
        for row in envRows { stops.append(row.keyBox.field) }
        stops.append(addVarButton)
        for row in excludeRows { stops.append(row.pathBox.field) }
        // The footer is one vertical stop anchored on Add (its default focus); Cancel is reached
        // from it with Left/Right, not Up/Down.
        stops += [addExcludeButton, addButton]
        return stops
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

    /// The vertical stop that represents the current focus — the focused stop itself, or, when the
    /// focus is on an env row's value box or remove button, that row's KEY field (its row anchor).
    private func currentVerticalAnchor(in stops: [NSView]) -> NSView? {
        if let direct = stops.first(where: isFocused) { return direct }
        for row in envRows where isFocused(row.valueBox.field) || isFocused(row.removeButton) {
            return row.keyBox.field
        }
        for row in excludeRows where isFocused(row.removeButton) { return row.pathBox.field }
        // The folder Choose button shares the folder field's vertical stop; it's reached with Right.
        if isFocused(folderPicker.chooseButton) { return folderPicker.field.field }
        // Cancel and Delete share the footer's vertical stop (Add); they're reached with Left/Right.
        if isFocused(cancelButton) || isFocused(deleteButton) { return addButton }
        return nil
    }

    private func isFocused(_ view: NSView) -> Bool { KeyboardFocus.isFocused(view, in: window) }

    /// Tab/Shift-Tab traverse the form's own stops, exactly like Down/Up. Without this the field
    /// editor leaked Tab to AppKit's default key-view loop while Tab on the form's buttons was
    /// consumed as advance/retreat — the same key doing two different things in one card.
    private func wireField(_ box: FieldBox) {
        box.onChange = { [weak self] in self?.refreshValidity() }
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

    // MARK: actions

    private func layoutChanged(_ index: Int) {
        layoutCaption.stringValue = layoutCaptions[min(index, layoutCaptions.count - 1)]
        customDetail.isHidden = (layoutChoice != .custom)
        refreshValidity()
    }

    /// The caption under the ＋ Add path button. Says what the field does and, because the word
    /// alone invites the wrong reading, that it is scoped to clones and is not a gitignore.
    /// Mirrors `WorkspacesParser`'s `clone_exclude` guard. A blank row is not invalid, it is
    /// simply not an entry, and `buildWorkspace` drops it.
    static func excludeIsInvalid(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~")
            || trimmed.split(separator: "/").contains("..")
            || trimmed.contains("\"")
    }

    static let excludeCaptionText =
        "Paths a clone starts without. Applies only when this workspace is cloned, not to git."

    @discardableResult
    private func addExcludeRow() -> CloneExcludeRow {
        let row = CloneExcludeRow { [weak self] row in self?.removeExcludeRow(row) }
        wireField(row.pathBox)
        row.removeButton.isKeyboardFocusable = true
        row.removeButton.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        row.removeButton.onArrowDown = { [weak self] in self?.moveVertical(1) }
        // Left/Right step across the row: path · ✕, the same shape an env row uses for KEY · value · ✕.
        row.pathBox.onArrowRight = { [weak self, weak row] in self?.focus(row?.removeButton) }
        row.pathBox.onEnter = { [weak self, weak row] in self?.focus(row?.removeButton) }
        row.removeButton.onArrowLeft = { [weak self, weak row] in self?.focus(row?.pathBox.field) }
        row.pathBox.onTab = { [weak self] in self?.moveTab(1) }
        excludeRows.append(row)
        excludeStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: excludeStack.widthAnchor).isActive = true
        window?.makeFirstResponder(row.pathBox.field)
        refreshValidity()
        return row
    }

    private func removeExcludeRow(_ row: CloneExcludeRow) {
        excludeRows.removeAll { $0 === row }
        excludeStack.removeArrangedSubview(row)
        row.removeFromSuperview()
        window?.makeFirstResponder(addExcludeButton)
        refreshValidity()
    }

    @discardableResult
    private func addEnvRow() -> EnvRow {
        let row = EnvRow { [weak self] row in self?.removeEnvRow(row) }
        wireField(row.keyBox)
        wireField(row.valueBox)
        row.removeButton.isKeyboardFocusable = true
        row.removeButton.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        row.removeButton.onArrowDown = { [weak self] in self?.moveVertical(1) }
        // Left/Right step across the row: KEY · value · ✕. Return advances the same way.
        row.keyBox.onArrowRight = { [weak self, weak row] in self?.focus(row?.valueBox.field) }
        row.keyBox.onEnter = { [weak self, weak row] in self?.focus(row?.valueBox.field) }
        row.valueBox.onArrowLeft = { [weak self, weak row] in self?.focus(row?.keyBox.field) }
        row.valueBox.onArrowRight = { [weak self, weak row] in self?.focus(row?.removeButton) }
        row.valueBox.onEnter = { [weak self, weak row] in self?.focus(row?.removeButton) }
        row.removeButton.onArrowLeft = { [weak self, weak row] in self?.focus(row?.valueBox.field) }
        // A row is ONE vertical stop (its KEY box), so Tab walks the pair in reading order — KEY →
        // value → the next row — rather than `moveVertical` jumping from KEY straight to the next
        // row and silently skipping the value the user was about to type.
        row.keyBox.onTab = { [weak self, weak row] in self?.focus(row?.valueBox.field) }
        row.valueBox.onTab = { [weak self] in self?.moveTab(1) }
        row.valueBox.onBacktab = { [weak self, weak row] in self?.focus(row?.keyBox.field) }
        envRows.append(row)
        envStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: envStack.widthAnchor).isActive = true
        window?.makeFirstResponder(row.keyBox.field)
        refreshValidity()
        return row
    }

    /// Seed the fields from the workspace being edited (a no-op when adding). The layout choice is
    /// reverse-derived from the recipe: a workspace whose recipe doesn't map cleanly onto Minimal or
    /// Editor+AI+Shell — or that focuses a non-`.main` region — opens as Custom so every field round
    /// trips. `titleEditedByUser` is set so choosing a folder later won't overwrite the loaded name.
    private func prefill() {
        guard let ws = editingWorkspace else { return }
        titleEditedByUser = true
        titleField.setText(ws.title)
        folderPicker.setText(PathDisplay.abbreviatingHome(ws.path.path))
        let choice = layoutChoice(for: ws)
        layoutSegment.setSelection(Self.layoutIndex(for: choice))
        if choice == .custom {
            mainField.setText(ws.main ?? "")
            rightField.setText(ws.right ?? "")
            bottomField.setText(ws.bottom ?? "")
            focusSegment.setSelection(Self.focusIndex(for: ws.focus))
        }
        for key in ws.env.keys.sorted() {
            let row = addEnvRow()
            row.keyBox.setText(key)
            row.valueBox.setText(ws.env[key] ?? "")
        }
        // Authored order, not sorted: the config keeps a list, so the form has to show it as one.
        for excluded in ws.cloneExclude { addExcludeRow().pathBox.setText(excluded) }
    }

    /// The preset a workspace maps back to: Minimal / Editor+AI+Shell only when the recipe matches
    /// *and* focus is the default `.main` (those presets can't express a focus); otherwise Custom,
    /// which carries every field verbatim.
    private func layoutChoice(for ws: Workspace) -> LayoutChoice {
        if ws.focus == .main, ws.main == nil, ws.right == nil, ws.bottom == nil { return .minimal }
        if ws.focus == .main, ws.bottom == "shell", matchesEditorAIPreset(ws) { return .editorAIShell }
        return .custom
    }

    /// A workspace reads back as the "Editor + AI + Shell" preset when its editor/AI are either the
    /// currently-configured pair or the built-in default — so a workspace stamped before the user
    /// changed the setting still shows as the preset rather than dropping to Custom.
    private func matchesEditorAIPreset(_ ws: Workspace) -> Bool {
        (ws.main == presetEditor && ws.right == presetAI)
            || (ws.main == GeneralConfig.defaultEditor && ws.right == GeneralConfig.defaultAI)
    }

    private static func layoutIndex(for choice: LayoutChoice) -> Int {
        switch choice {
        case .minimal: return 0
        case .editorAIShell: return 1
        case .custom: return 2
        }
    }

    private static func focusIndex(for region: Workspace.Region) -> Int {
        switch region {
        case .main: return 0
        case .right: return 1
        case .bottom: return 2
        }
    }

    private func focus(_ view: NSView?) {
        guard let view else { return }
        window?.makeFirstResponder(view)
    }

    private func removeEnvRow(_ row: EnvRow) {
        envRows.removeAll { $0 === row }
        envStack.removeArrangedSubview(row)
        row.removeFromSuperview()
        window?.makeFirstResponder(addVarButton)
        refreshValidity()
    }

    private func submit() {
        if let firstInvalid = validate(includeRequired: true) {
            window?.makeFirstResponder(firstInvalid)
            return
        }
        guard let workspace = buildWorkspace() else { return }
        onSubmit(workspace)
    }

    // MARK: model + validation

    private var layoutChoice: LayoutChoice {
        switch layoutSegment.selectedIndex {
        case 0: return .minimal
        case 2: return .custom
        default: return .editorAIShell
        }
    }

    private var focusRegion: Workspace.Region {
        switch focusSegment.selectedIndex {
        case 1: return .right
        case 2: return .bottom
        default: return .main
        }
    }

    private func buildWorkspace() -> Workspace? {
        let title = titleField.text.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, let folder = resolvedFolder() else { return nil }
        let recipe = recipeForChoice()
        var env: [String: String] = [:]
        for row in envRows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }  // a blank key isn't a variable
            env[key] = row.value.trimmingCharacters(in: .whitespaces)
        }
        // A blank row is someone who pressed ＋ and changed their mind, not an entry.
        let cloneExclude =
            excludeRows
            .map { $0.path.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Workspace(
            title: title, path: folder,
            main: recipe.main, right: recipe.right, bottom: recipe.bottom, focus: recipe.focus, env: env,
            cloneExclude: cloneExclude)
    }

    private func recipeForChoice() -> (main: String?, right: String?, bottom: String?, focus: Workspace.Region) {
        switch layoutChoice {
        case .minimal: return (nil, nil, nil, .main)
        case .editorAIShell: return (presetEditor, presetAI, "shell", .main)
        case .custom:
            func normalized(_ text: String) -> String? {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            return (normalized(mainField.text), normalized(rightField.text), normalized(bottomField.text), focusRegion)
        }
    }

    private func resolvedFolder() -> URL? {
        let text = folderPicker.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return URL(fileURLWithPath: PathDisplay.expandingHome(text), isDirectory: true)
    }

    /// Update every field's inline message and return the first offending field to focus (nil when
    /// submittable). `includeRequired` gates the mandatory-but-empty checks: false for the live
    /// pass (don't flag an untouched field), true on a submit attempt.
    @discardableResult
    private func validate(includeRequired: Bool) -> NSView? {
        var firstInvalid: NSView?
        func flag(_ group: LabeledField?, field: NSView, _ message: String?) {
            group?.setMessage(message)
            if message != nil, firstInvalid == nil { firstInvalid = field }
        }

        let title = titleField.text.trimmingCharacters(in: .whitespaces)
        var titleMessage: String?
        if !title.isEmpty, title.contains(where: { "[]#\"".contains($0) }) {
            titleMessage = "Can't contain [ ] # or \"."
        } else if !title.isEmpty, existingTitles.contains(title) {
            titleMessage = "A workspace with this name already exists."
        } else if includeRequired, title.isEmpty {
            titleMessage = "Enter a workspace name."
        }
        flag(titleGroup, field: titleField.field, titleMessage)

        let folderText = folderPicker.text.trimmingCharacters(in: .whitespaces)
        var folderMessage: String?
        if includeRequired, folderText.isEmpty {
            folderMessage = "Choose or type a workspace folder."
        } else if folderText.contains("\"") {
            folderMessage = "The path can't contain a \" character."  // the format has no escaping
        } else if !folderText.isEmpty, let folder = resolvedFolder(), !PathDisplay.isDirectory(folder) {
            folderMessage = "That folder doesn't exist."
        }
        flag(folderGroup, field: folderPicker.field.field, folderMessage)

        // Custom command fields only matter (and only show) while the Custom layout is selected.
        if layoutChoice == .custom {
            for (box, group) in [(mainField, mainGroup), (rightField, rightGroup), (bottomField, bottomGroup)] {
                flag(group, field: box.field, box.text.contains("\"") ? "Can't contain a \" character." : nil)
            }
        } else {
            for group in [mainGroup, rightGroup, bottomGroup] { group?.setMessage(nil) }
        }

        // A `=` or `"` in a name, or a `"` in a value, can't round-trip (the parser splits env on
        // the first `=` and the format has no escaping) — so reject them.
        func keyIsBad(_ row: EnvRow) -> Bool { row.key.contains("=") || row.key.contains("\"") }
        let badEnvRow = envRows.first { keyIsBad($0) || $0.value.contains("\"") }
        envError.stringValue =
            badEnvRow == nil ? "" : "Names can't use = or \" and values can't use \"."
        envError.isHidden = (badEnvRow == nil)
        if let badEnvRow, firstInvalid == nil {
            firstInvalid = keyIsBad(badEnvRow) ? badEnvRow.keyBox.field : badEnvRow.valueBox.field
        }

        // The same rules `WorkspacesParser` enforces on load, said here instead of on a log line
        // nobody reads: an entry that leaves the workspace is dropped when the file is next parsed,
        // so without this the path a person typed silently disappears. A `"` cannot round-trip
        // either, for the reason an env value cannot.
        let badExcludeRow = excludeRows.first { Self.excludeIsInvalid($0.path) }
        excludeError.stringValue =
            badExcludeRow == nil ? "" : "Paths stay inside the workspace: no leading / or ~, no .., no \"."
        excludeError.isHidden = (badExcludeRow == nil)
        if let badExcludeRow, firstInvalid == nil { firstInvalid = badExcludeRow.pathBox.field }

        return firstInvalid
    }

    private func refreshValidity() { validate(includeRequired: false) }

    // MARK: layout helpers

    /// A small-caps caption; a required field marks it with a trailing accent asterisk.
    private static func caption(_ text: String, required: Bool) -> NSTextField {
        FieldCaption(text, required: required)
    }

    /// Same as `Self.caption`, but for a caption built directly into a stack (not wrapped by a
    /// `LabeledField`, which retains its own) — retains the created `FieldCaption` in `captions`
    /// so `reapplyTheme()` can reach it too.
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

    /// A single control wrapped so it hugs the leading edge (doesn't stretch to full width).
    private static func leadingWrap(_ view: NSView) -> NSView {
        let stack = NSStackView(views: [view])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        return stack
    }
}

// MARK: - Env row (a form-specific composite of the shared `FieldBox` / `AppButton` primitives)

/// One environment-variable row: a KEY box, a `=`, a VALUE box, and a remove button.
final class EnvRow: NSView {
    let keyBox = FieldBox(placeholder: "KEY")
    let valueBox = FieldBox(placeholder: "value")
    /// A focus stop in the form's keyboard flow (arrow to it, Return removes the row).
    let removeButton = AppButton(title: "✕", variant: .secondary)
    /// Retained (not a throwaway init-local) so `reapplyTheme()` can recolor it — otherwise this
    /// static `=` label would go stranded, stale forever after a theme swap while the row is up.
    private let equals = NSTextField(labelWithString: "=")

    var key: String { keyBox.text }
    var value: String { valueBox.text }

    init(onRemove: @escaping (EnvRow) -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        keyBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueBox.setContentHuggingPriority(.defaultLow, for: .horizontal)

        equals.font = .systemFont(ofSize: 13)
        equals.textColor = Theme.current.chrome.ink(.muted)
        equals.setContentHuggingPriority(.required, for: .horizontal)

        removeButton.setContentHuggingPriority(.required, for: .horizontal)
        removeButton.onTap = { [weak self] in if let self { onRemove(self) } }

        let stack = NSStackView(views: [keyBox, equals, valueBox, removeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The KEY box stays narrower than the value box (a name is short, a value can be long).
            keyBox.widthAnchor.constraint(equalTo: valueBox.widthAnchor, multiplier: 0.6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Re-apply the live chrome colors after a config change — no relaunch: the KEY/value boxes,
    /// the remove button (all `ThemeReapplying`), and the `=` label baked in at construction.
    func reapplyTheme() {
        keyBox.reapplyTheme()
        valueBox.reapplyTheme()
        removeButton.reapplyTheme()
        equals.textColor = Theme.current.chrome.ink(.muted)
    }
}

// MARK: - Clone-exclude row

/// One `clone_exclude` entry: a path box and a remove button. `EnvRow` without the key half,
/// which is the whole difference — this is a list, not a map.
final class CloneExcludeRow: NSView {
    let pathBox = FieldBox(placeholder: ".next")
    /// A focus stop in the form's keyboard flow (arrow to it, Return removes the row).
    let removeButton = AppButton(title: "✕", variant: .secondary)

    var path: String { pathBox.text }

    init(onRemove: @escaping (CloneExcludeRow) -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        pathBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        removeButton.setContentHuggingPriority(.required, for: .horizontal)
        removeButton.onTap = { [weak self] in if let self { onRemove(self) } }

        let stack = NSStackView(views: [pathBox, removeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        pathBox.reapplyTheme()
        removeButton.reapplyTheme()
    }
}
