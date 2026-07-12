import AppKit

/// The "Add Workspace" form card, opened from the ⌘P command and the ⌘⇧P picker's ＋ row. It
/// collects a folder, title, layout recipe, and env vars, builds a `Workspace`, and hands it to
/// `onSubmit` — the host writes it to the `workspaces` file and opens it. A `ModalOverlay` like
/// the palettes (shared card + backdrop + spring), but a multi-field form.
///
/// Fully keyboard-driven: Up/Down move between fields, Left/Right pick within a segmented control,
/// Return advances to the next field (opens the folder panel when the empty folder field is
/// focused), ⌘Return submits, Esc cancels. Every input is full width, the focused field/control
/// reads as a muted fill, and each field shows its own validation message beneath it.
final class AddWorkspaceOverlay: NSView, ModalOverlay {
    /// A layout preset; `custom` reveals the raw recipe fields.
    private enum LayoutChoice { case minimal, editorAIShell, custom }

    private static let layoutCaptions = [
        "One shell, drawers closed", "nvim, claude, shell", "Set each region yourself",
    ]

    private let existingTitles: Set<String>
    private let onSubmit: (Workspace) -> Void
    private let onCancel: () -> Void

    private let card = CardView()
    private var isDismissing = false
    /// Retained (not a throwaway init-local) so `reapplyTheme()` can recolor it in place.
    private let header = NSTextField(labelWithString: "New Workspace")

    private let titleField = FieldBox(placeholder: "Workspace name")
    private let folderField = FieldBox(placeholder: "Click to choose, or type a path")
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
    private let envError = NSTextField(labelWithString: "")
    private let addVarButton = AppButton(title: "＋ Add variable", variant: .muted)
    private let cancelButton = AppButton(title: "Cancel", variant: .secondary, keyEquivalent: "\u{1b}")
    private let addButton = AppButton(
        title: "Add Workspace", variant: .primary, keyEquivalent: "\r", keyEquivalentModifierMask: .command)

    init(
        existingTitles: Set<String>, background: NSColor,
        onSubmit: @escaping (Workspace) -> Void, onCancel: @escaping () -> Void
    ) {
        self.existingTitles = existingTitles
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let backdrop = BackdropView(onClick: onCancel)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = background.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = FloatShadow.edge.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        FloatShadow.applyShadow(to: card)

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
        guard !isDismissing else { return }
        isDismissing = true
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isDismissing ? nil : super.hitTest(point)
    }

    /// Re-apply the form's theme-dependent colors after a live theme change, IN PLACE — unlike
    /// the palettes, this form holds uncommitted typed values (fields + dynamic env rows) that a
    /// rebuild would lose, so nothing here is ever rebuilt, only recolored. Every leaf control
    /// conforms to `ThemeReapplying` (Task 6/7), so they're recolored as one group instead of a
    /// type-switch; `EnvRow` and `LabeledField` get their own small `reapplyTheme()` for the same
    /// reason KeybindRow does — a composite that owns otherwise-stranded static labels.
    func reapplyTheme() {
        let chrome = Theme.current.chrome
        card.layer?.backgroundColor = chrome.background.nsColor.cgColor
        card.layer?.borderColor = FloatShadow.edge.cgColor
        header.textColor = chrome.foreground.nsColor
        layoutCaption.textColor = chrome.ink(alpha: 0.45)
        envError.textColor = chrome.destructive.nsColor

        let controls: [ThemeReapplying] = [
            titleField, folderField, mainField, rightField, bottomField,
            layoutSegment, focusSegment, addVarButton, cancelButton, addButton,
        ]
        controls.forEach { $0.reapplyTheme() }
        envRows.forEach { $0.reapplyTheme() }
        for group in [titleGroup, folderGroup, mainGroup, rightGroup, bottomGroup] {
            group?.reapplyTheme()
        }
        captions.forEach { $0.reapplyTheme() }
    }

    // MARK: content

    private func buildContent() -> NSStackView {
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = Theme.current.chrome.foreground.nsColor

        wireField(titleField)
        titleField.onChange = { [weak self] in
            self?.titleEditedByUser = true
            self?.refreshValidity()
        }
        let titleGroup = LabeledField(caption: Self.caption("WORKSPACE NAME", required: true), control: titleField)
        self.titleGroup = titleGroup

        wireField(folderField)
        folderField.onEmptyClick = { [weak self] in self?.chooseFolder() }
        folderField.onEnter = { [weak self] in
            guard let self else { return }
            if self.folderField.text.trimmingCharacters(in: .whitespaces).isEmpty {
                self.chooseFolder()
            } else {
                self.moveVertical(1)
            }
        }
        let folderGroup = LabeledField(caption: Self.caption("FOLDER", required: true), control: folderField)
        self.folderGroup = folderGroup

        layoutSegment.onChange = { [weak self] index in self?.layoutChanged(index) }
        wireSegment(layoutSegment)
        wireSegment(focusSegment)
        layoutCaption.font = .systemFont(ofSize: 11)
        layoutCaption.textColor = Theme.current.chrome.ink(alpha: 0.45)
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

        cancelButton.onTap = { [weak self] in self?.onCancel() }
        addButton.onTap = { [weak self] in self?.submit() }
        for button in [addVarButton, cancelButton, addButton] {
            button.isKeyboardFocusable = true
            button.onArrowUp = { [weak self] in self?.moveVertical(-1) }
            button.onArrowDown = { [weak self] in self?.moveVertical(1) }
        }
        // Add · Cancel are a horizontal pair — Left/Right move between them (matching the layout).
        addButton.onArrowLeft = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onArrowRight = { [weak self] in self?.focus(self?.addButton) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = Self.hStack([spacer, cancelButton, addButton], spacing: 8)

        let content = NSStackView(views: [
            header, titleGroup, folderGroup, layoutGroup, customDetail, envGroup, footer,
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
        var stops: [NSView] = [titleField.field, folderField.field, layoutSegment]
        if layoutChoice == .custom {
            stops += [mainField.field, rightField.field, bottomField.field, focusSegment]
        }
        for row in envRows { stops.append(row.keyBox.field) }
        // The footer is one vertical stop anchored on Add (its default focus); Cancel is reached
        // from it with Left/Right, not Up/Down.
        stops += [addVarButton, addButton]
        return stops
    }

    private func moveVertical(_ delta: Int) {
        let stops = verticalStops()
        let anchor = currentVerticalAnchor(in: stops).flatMap { anchor in stops.firstIndex { $0 === anchor } }
        guard let next = KeyboardFocus.step(from: anchor, delta: delta, count: stops.count) else { return }
        window?.makeFirstResponder(stops[next])
    }

    /// The vertical stop that represents the current focus — the focused stop itself, or, when the
    /// focus is on an env row's value box or remove button, that row's KEY field (its row anchor).
    private func currentVerticalAnchor(in stops: [NSView]) -> NSView? {
        if let direct = stops.first(where: isFocused) { return direct }
        for row in envRows where isFocused(row.valueBox.field) || isFocused(row.removeButton) {
            return row.keyBox.field
        }
        if isFocused(cancelButton) { return addButton }  // Cancel shares the footer's stop
        return nil
    }

    private func isFocused(_ view: NSView) -> Bool { KeyboardFocus.isFocused(view, in: window) }

    private func wireField(_ box: FieldBox) {
        box.onChange = { [weak self] in self?.refreshValidity() }
        box.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        box.onArrowDown = { [weak self] in self?.moveVertical(1) }
        box.onEsc = { [weak self] in self?.onCancel() }
        box.onSubmit = { [weak self] in self?.submit() }
    }

    private func wireSegment(_ segment: SegmentedControl) {
        segment.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        segment.onArrowDown = { [weak self] in self?.moveVertical(1) }
    }

    // MARK: actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.folderField.setText(self.abbreviate(url.path))
            if !self.titleEditedByUser { self.titleField.setText(url.lastPathComponent) }
            self.refreshValidity()
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            panel.begin(completionHandler: handle)
        }
    }

    private func layoutChanged(_ index: Int) {
        layoutCaption.stringValue = Self.layoutCaptions[min(index, Self.layoutCaptions.count - 1)]
        customDetail.isHidden = (layoutChoice != .custom)
        refreshValidity()
    }

    private func addEnvRow() {
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
        envRows.append(row)
        envStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: envStack.widthAnchor).isActive = true
        window?.makeFirstResponder(row.keyBox.field)
        refreshValidity()
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
        return Workspace(
            title: title, path: folder,
            main: recipe.main, right: recipe.right, bottom: recipe.bottom, focus: recipe.focus, env: env)
    }

    private func recipeForChoice() -> (main: String?, right: String?, bottom: String?, focus: Workspace.Region) {
        switch layoutChoice {
        case .minimal: return (nil, nil, nil, .main)
        case .editorAIShell: return ("nvim", "claude", "shell", .main)
        case .custom:
            func normalized(_ text: String) -> String? {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            return (normalized(mainField.text), normalized(rightField.text), normalized(bottomField.text), focusRegion)
        }
    }

    private func resolvedFolder() -> URL? {
        let text = folderField.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return URL(fileURLWithPath: (text as NSString).expandingTildeInPath, isDirectory: true)
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
            titleMessage = "Can’t contain [ ] # or \"."
        } else if !title.isEmpty, existingTitles.contains(title) {
            titleMessage = "A workspace with this name already exists."
        } else if includeRequired, title.isEmpty {
            titleMessage = "Enter a workspace name."
        }
        flag(titleGroup, field: titleField.field, titleMessage)

        let folderText = folderField.text.trimmingCharacters(in: .whitespaces)
        var folderMessage: String?
        if includeRequired, folderText.isEmpty {
            folderMessage = "Choose or type a workspace folder."
        } else if folderText.contains("\"") {
            folderMessage = "The path can’t contain a \" character."  // the format has no escaping
        } else if !folderText.isEmpty, let folder = resolvedFolder(), !directoryExists(folder) {
            folderMessage = "That folder doesn’t exist."
        }
        flag(folderGroup, field: folderField.field, folderMessage)

        // Custom command fields only matter (and only show) while the Custom layout is selected.
        if layoutChoice == .custom {
            for (box, group) in [(mainField, mainGroup), (rightField, rightGroup), (bottomField, bottomGroup)] {
                flag(group, field: box.field, box.text.contains("\"") ? "Can’t contain a \" character." : nil)
            }
        } else {
            for group in [mainGroup, rightGroup, bottomGroup] { group?.setMessage(nil) }
        }

        // A `=` or `"` in a name, or a `"` in a value, can't round-trip (the parser splits env on
        // the first `=` and the format has no escaping) — so reject them.
        func keyIsBad(_ row: EnvRow) -> Bool { row.key.contains("=") || row.key.contains("\"") }
        let badEnvRow = envRows.first { keyIsBad($0) || $0.value.contains("\"") }
        envError.stringValue =
            badEnvRow == nil ? "" : "Names can’t use = or \" and values can’t use \"."
        envError.isHidden = (badEnvRow == nil)
        if let badEnvRow, firstInvalid == nil {
            firstInvalid = keyIsBad(badEnvRow) ? badEnvRow.keyBox.field : badEnvRow.valueBox.field
        }

        return firstInvalid
    }

    private func refreshValidity() { validate(includeRequired: false) }

    // MARK: layout helpers

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

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

/// A small-caps field caption ("WORKSPACE NAME ✳"), built by `AddWorkspaceOverlay.caption(_:required:)`.
/// Its attributed string bakes in two color runs (the label ink, the required asterisk's accent)
/// that `LabeledField` — a shared primitive with no insight into that structure — can't recolor
/// itself, so this rebuilds its own string fresh in `reapplyTheme()` and conforms to
/// `ThemeReapplying` so `LabeledField` can reach it generically.
private final class FieldCaption: NSTextField, ThemeReapplying {
    private let text: String
    private let isRequired: Bool

    init(_ text: String, required: Bool) {
        self.text = text
        self.isRequired = required
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        translatesAutoresizingMaskIntoConstraints = false
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        let string = NSMutableAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: Theme.current.chrome.ink(alpha: 0.4),
                .kern: 0.6,
            ])
        if isRequired {
            string.append(
                NSAttributedString(
                    string: " ✳",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                        .foregroundColor: Theme.current.chrome.accent.nsColor,
                    ]))
        }
        attributedStringValue = string
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
        equals.textColor = Theme.current.chrome.ink(alpha: 0.4)
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
        equals.textColor = Theme.current.chrome.ink(alpha: 0.4)
    }
}
