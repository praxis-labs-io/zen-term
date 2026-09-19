import AppKit

final class AddWorkspaceOverlay: NSView, ModalOverlay {
    private enum LayoutChoice { case minimal, editorAIShell, custom }

    /// Snapshotted at open so the caption shown and the recipe stored cannot disagree.
    private let presetEditor: String
    private let presetAI: String

    private lazy var layoutCaptions: [String] = [
        "One shell, drawers closed", "\(presetEditor), \(presetAI), shell", "Set each region yourself",
    ]

    private let editingWorkspace: Workspace?
    private let existingTitles: Set<String>
    private let onSubmit: (Workspace) -> Void
    private let onCancel: () -> Void
    private let onDelete: (() -> Void)?

    private let card = CardView()
    private var footerDivider: ThemeReapplying?
    private var dismiss = DismissGate()
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

    private var captions: [FieldCaption] = []
    private var envRows: [EnvRow] = []
    private let envStack = NSStackView()
    private let envError = NSTextField(labelWithString: "")
    private let addVarButton = AppButton(title: "＋ Add variable", variant: .muted)
    private let carryPicker = CarryPicker()
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
            card.heightAnchor.constraint(lessThanOrEqualToConstant: FormCard.maxHeight),

            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        prefill()
        layoutChanged(layoutSegment.selectedIndex)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func focusInitialResponder() { window?.makeFirstResponder(titleField.field) }

    func animateIn() {
        superview?.layoutSubtreeIfNeeded()
        Motion.springScaleFade(card, appearing: true)
    }

    func animateOut(completion: @escaping () -> Void) {
        guard dismiss.begin() else { return }
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        dismiss.isDismissing ? nil : super.hitTest(point)
    }

    /// Claims Esc here because a focused field routes it through its field editor, which never bubbles.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ModalEscape.handle(
            event, in: window, dismissing: dismiss.isDismissing, close: { self.onCancel() }
        ) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Recolors in place rather than rebuilding, which would lose uncommitted typed values.
    func reapplyTheme() {
        let chrome = Theme.current.chrome
        CardChrome.reapplyTheme(to: card)
        header.textColor = chrome.foreground.nsColor
        layoutCaption.textColor = chrome.ink(.muted)
        envError.textColor = chrome.destructive.nsColor

        let controls: [ThemeReapplying] = [
            titleField, folderPicker, mainField, rightField, bottomField,
            layoutSegment, focusSegment, addVarButton, cancelButton, addButton, deleteButton,
        ]
        controls.forEach { $0.reapplyTheme() }
        carryPicker.reapplyTheme()
        footerDivider?.reapplyTheme()
        envRows.forEach { $0.reapplyTheme() }
        for group in [titleGroup, folderGroup, mainGroup, rightGroup, bottomGroup] {
            group?.reapplyTheme()
        }
        captions.forEach { $0.reapplyTheme() }
    }

    private func buildContent() -> NSStackView {
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = Theme.current.chrome.foreground.nsColor
        header.stringValue = editingWorkspace == nil ? "Add Workspace" : "Edit Workspace"

        wireField(titleField)
        titleField.onChange = { [weak self] in
            self?.titleEditedByUser = true
            self?.refreshValidity()
        }
        let titleGroup = LabeledField(caption: Self.caption("WORKSPACE NAME", required: true), control: titleField)
        self.titleGroup = titleGroup

        wireField(folderPicker.field)
        folderPicker.onPicked = { [weak self] url in
            guard let self else { return }
            if !self.titleEditedByUser { self.titleField.setText(url.lastPathComponent) }
            self.folderChanged()
        }
        folderPicker.field.onChange = { [weak self] in self?.folderChanged() }
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

        carryPicker.onChanged = { [weak self] in self?.refreshValidity() }
        carryPicker.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        carryPicker.onArrowDown = { [weak self] in self?.moveVertical(1) }
        carryPicker.onTab = { [weak self] in self?.moveTab(1) }
        carryPicker.onBacktab = { [weak self] in self?.moveTab(-1) }
        carryPicker.onFocusLost = { [weak self] in self?.focus(self?.addVarButton) }
        let carryGroup = Self.vStack(
            [caption("COPY INTO NEW WORKTREES", required: false), carryPicker], spacing: 6)

        cancelButton.onTap = { [weak self] in self?.onCancel() }
        addButton.setTitle(editingWorkspace == nil ? "Add Workspace" : "Save")
        addButton.onTap = { [weak self] in self?.submit() }
        for button in [addVarButton, cancelButton, addButton] {
            button.isKeyboardFocusable = true
            button.onArrowUp = { [weak self] in self?.moveVertical(-1) }
            button.onArrowDown = { [weak self] in self?.moveVertical(1) }
            button.onTab = { [weak self] in self?.moveTab(1) }
            button.onBacktab = { [weak self] in self?.moveTab(-1) }
        }
        addButton.onArrowLeft = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onArrowRight = { [weak self] in self?.focus(self?.addButton) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var footerViews: [NSView] = [spacer, cancelButton, addButton]
        if onDelete != nil {
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
        addButton.onTab = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onBacktab = { [weak self] in self?.focus(self?.addButton) }
        if onDelete != nil {
            cancelButton.onTab = { [weak self] in self?.focus(self?.deleteButton) }
            deleteButton.onBacktab = { [weak self] in self?.focus(self?.cancelButton) }
        } else {
            cancelButton.onTab = { [weak self] in self?.moveTab(1) }
        }
        let footer = Self.hStack(footerViews, spacing: 8)

        let built = FormCard.content(
            rows: [header, titleGroup, folderGroup, layoutGroup, customDetail, envGroup, carryGroup],
            footer: footer, spacing: 14)
        footerDivider = built.divider
        return built.view
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

    private func verticalStops() -> [NSView] {
        var stops: [NSView] = [titleField.field, folderPicker.field.field, layoutSegment]
        if layoutChoice == .custom {
            stops += [mainField.field, rightField.field, bottomField.field, focusSegment]
        }
        for row in envRows { stops.append(row.keyBox.field) }
        stops.append(addVarButton)
        if let carryStop = carryPicker.focusStop { stops.append(carryStop) }
        stops.append(addButton)
        return stops
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
        for row in envRows where isFocused(row.valueBox.field) || isFocused(row.removeButton) {
            return row.keyBox.field
        }
        if isFocused(folderPicker.chooseButton) { return folderPicker.field.field }
        if isFocused(cancelButton) || isFocused(deleteButton) { return addButton }
        return nil
    }

    private func isFocused(_ view: NSView) -> Bool { KeyboardFocus.isFocused(view, in: window) }

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

    private func layoutChanged(_ index: Int) {
        layoutCaption.stringValue = layoutCaptions[min(index, layoutCaptions.count - 1)]
        customDetail.isHidden = (layoutChoice != .custom)
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
        row.keyBox.onArrowRight = { [weak self, weak row] in self?.focus(row?.valueBox.field) }
        row.keyBox.onEnter = { [weak self, weak row] in self?.focus(row?.valueBox.field) }
        row.valueBox.onArrowLeft = { [weak self, weak row] in self?.focus(row?.keyBox.field) }
        row.valueBox.onArrowRight = { [weak self, weak row] in self?.focus(row?.removeButton) }
        row.valueBox.onEnter = { [weak self, weak row] in self?.focus(row?.removeButton) }
        row.removeButton.onArrowLeft = { [weak self, weak row] in self?.focus(row?.valueBox.field) }
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
        carryPicker.setCarried(ws.carry)
        carryPicker.workspaceFolder = ws.path
    }

    private func layoutChoice(for ws: Workspace) -> LayoutChoice {
        if ws.focus == .main, ws.main == nil, ws.right == nil, ws.bottom == nil { return .minimal }
        if ws.focus == .main, ws.bottom == "shell", matchesEditorAIPreset(ws) { return .editorAIShell }
        return .custom
    }

    /// Accepts the built-in default pair too, so a workspace stamped before a config change stays the preset.
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
            guard !key.isEmpty else { continue }
            env[key] = row.value.trimmingCharacters(in: .whitespaces)
        }
        return Workspace(
            title: title, path: folder,
            main: recipe.main, right: recipe.right, bottom: recipe.bottom, focus: recipe.focus,
            env: env, carry: carryPicker.carried)
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

    /// Rejects `=` and `"` where they cannot round-trip: the format has no escaping.
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
            folderMessage = "The path can't contain a \" character."
        } else if !folderText.isEmpty, let folder = resolvedFolder(), !PathDisplay.isDirectory(folder) {
            folderMessage = "That folder doesn't exist."
        }
        flag(folderGroup, field: folderPicker.field.field, folderMessage)

        if layoutChoice == .custom {
            for (box, group) in [(mainField, mainGroup), (rightField, rightGroup), (bottomField, bottomGroup)] {
                flag(group, field: box.field, box.text.contains("\"") ? "Can't contain a \" character." : nil)
            }
        } else {
            for group in [mainGroup, rightGroup, bottomGroup] { group?.setMessage(nil) }
        }

        func keyIsBad(_ row: EnvRow) -> Bool { row.key.contains("=") || row.key.contains("\"") }
        let badEnvRow = envRows.first { keyIsBad($0) || $0.value.contains("\"") }
        envError.stringValue =
            badEnvRow == nil ? "" : "Names can't use = or \" and values can't use \"."
        envError.isHidden = (badEnvRow == nil)
        if let badEnvRow, firstInvalid == nil {
            firstInvalid = keyIsBad(badEnvRow) ? badEnvRow.keyBox.field : badEnvRow.valueBox.field
        }

        return firstInvalid
    }

    private func refreshValidity() { validate(includeRequired: false) }

    private func folderChanged() {
        carryPicker.workspaceFolder = resolvedFolder().flatMap { PathDisplay.isDirectory($0) ? $0 : nil }
        refreshValidity()
    }

    private static func caption(_ text: String, required: Bool) -> NSTextField {
        FieldCaption(text, required: required)
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

    private static func leadingWrap(_ view: NSView) -> NSView {
        let stack = NSStackView(views: [view])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        return stack
    }
}

final class EnvRow: NSView {
    let keyBox = FieldBox(placeholder: "KEY")
    let valueBox = FieldBox(placeholder: "value")
    let removeButton = AppButton(title: "✕", variant: .secondary)
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
            keyBox.widthAnchor.constraint(equalTo: valueBox.widthAnchor, multiplier: 0.6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        keyBox.reapplyTheme()
        valueBox.reapplyTheme()
        removeButton.reapplyTheme()
        equals.textColor = Theme.current.chrome.ink(.muted)
    }
}
