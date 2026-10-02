import AppKit

final class WorkspaceFormOverlay: NSView, ModalOverlay {
    // Taller than `FormCard.maxHeight` so the tab drawing and a few env rows fit before the body scrolls.
    static let maxHeight: CGFloat = 580
    static let width: CGFloat = 640
    private static let nameWidth: CGFloat = 210
    private static let namePlaceholder = "Named after the folder"
    private static let submitChord = Chord(command: true, key: "⏎")
    private static let launchFocusChord = Chord(command: true, key: "l")

    private enum Problem {
        case view(NSView)
        case tabName(Int)
        case command(Int, Workspace.Region)
    }

    private enum FocusSpot {
        case chip
        case region(Workspace.Region)
        case elsewhere
    }

    private let editingWorkspace: Workspace?
    private let existingTitles: Set<String>
    private let onSubmit: (Workspace) -> Void
    private let onCancel: () -> Void
    private let onDelete: (() -> Void)?
    private var form: WorkspaceForm

    private let card = CardView()
    private var footerDivider: ThemeReapplying?
    private var dismiss = DismissGate()
    private let header = NSTextField(labelWithString: "")
    private let escapeCap = KeycapView(shortcut: "esc")

    private let titleField = FieldBox(placeholder: WorkspaceFormOverlay.namePlaceholder)
    private let folderPicker = DirectoryPickerField(placeholder: "Type a path, or Choose")
    private var titleGroup: LabeledField?
    private var folderGroup: LabeledField?

    private let tabStrip = WorkspaceTabStrip()
    private let drawing = WorkspaceTabDrawing()
    private var tabsGroup: LabeledField?

    private var captions: [FieldCaption] = []
    private var envRows: [EnvRow] = []
    private let envStack = NSStackView()
    private let envError = NSTextField(labelWithString: "")
    private let addVarButton = AppButton(title: "＋ Add variable", variant: .muted)
    private let carryPicker = CarryPicker()
    private let notice = NSTextField(labelWithString: "")
    private let undoButton = AppButton(title: "Undo", variant: .secondary)
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
        self.form = WorkspaceForm(editing: editing)
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

        let cardWidth = card.widthAnchor.constraint(equalToConstant: Self.width)
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
            card.heightAnchor.constraint(lessThanOrEqualToConstant: Self.maxHeight),

            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        prefill()
        renderTabs()
        refreshValidity()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var titleFieldForTesting: FieldBox { titleField }
    var folderFieldForTesting: DirectoryPickerField { folderPicker }
    var tabStripForTesting: WorkspaceTabStrip { tabStrip }
    var drawingForTesting: WorkspaceTabDrawing { drawing }
    var formForTesting: WorkspaceForm { form }
    var noticeForTesting: String? { notice.isHidden ? nil : notice.stringValue }
    var undoButtonForTesting: AppButton? { undoButton.isHidden ? nil : undoButton }

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
            event, in: window, dismissing: dismiss.isDismissing,
            close: { if !self.tabStrip.cancelRename() { self.onCancel() } }
        ) {
            return true
        }
        if Chord(event: event) == Self.launchFocusChord { return drawing.openFocusedAtFocusedRegion() }
        return super.performKeyEquivalent(with: event)
    }

    func owns(_ chord: Chord) -> Bool { chord == Self.submitChord || chord == Self.launchFocusChord }

    func handle(_ chord: KeyInterceptor.ReservedChord) -> Bool {
        switch chord {
        case .newTab: addTab()
        case .closeTab: removeTab(at: form.selected, focusingStrip: isStripFocused)
        case .moveTabLeft: moveSelectedTab(by: -1)
        case .moveTabRight: moveSelectedTab(by: 1)
        case .prevTab: selectTab(cycling: -1)
        case .nextTab: selectTab(cycling: 1)
        case .selectTab(let n): selectTab(n - 1)
        case .renameTab: tabStrip.beginRenamingSelected()
        default: return false
        }
        return true
    }

    /// Recolors in place rather than rebuilding, which would lose uncommitted typed values.
    func reapplyTheme() {
        let chrome = Theme.current.chrome
        CardChrome.reapplyTheme(to: card)
        header.textColor = chrome.foreground.nsColor
        envError.textColor = chrome.destructive.nsColor
        notice.textColor = chrome.ink(.subtle)
        escapeCap.reapplyTheme()

        let controls: [ThemeReapplying] = [
            titleField, folderPicker, addVarButton, undoButton, cancelButton, addButton, deleteButton,
        ]
        controls.forEach { $0.reapplyTheme() }
        tabStrip.reapplyTheme()
        drawing.reapplyTheme()
        carryPicker.reapplyTheme()
        footerDivider?.reapplyTheme()
        envRows.forEach { $0.reapplyTheme() }
        for group in [titleGroup, folderGroup, tabsGroup] { group?.reapplyTheme() }
        captions.forEach { $0.reapplyTheme() }
    }

    private func buildContent() -> NSStackView {
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = Theme.current.chrome.foreground.nsColor
        header.stringValue = editingWorkspace == nil ? "Add Workspace" : "Edit Workspace"
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerRow = Self.hStack([header, headerSpacer, escapeCap], spacing: 8)

        let nameRow = buildNameRow()
        let tabsGroup = buildTabsGroup()

        envStack.orientation = .vertical
        envStack.alignment = .leading
        envStack.spacing = 6
        addVarButton.onTap = { [weak self] in self?.addEnvRow() }
        envError.font = .systemFont(ofSize: 11, weight: .medium)
        envError.textColor = Theme.current.chrome.destructive.nsColor
        envError.isHidden = true
        let envControls = Self.vStack([envStack, Self.leadingWrap(addVarButton), envError], spacing: 8)
        let envGroup = Self.vStack([caption("Environment", required: false), envControls], spacing: 6)

        carryPicker.onChanged = { [weak self] in self?.refreshValidity() }
        carryPicker.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        carryPicker.onArrowDown = { [weak self] in self?.moveVertical(1) }
        carryPicker.onTab = { [weak self] in self?.moveTab(1) }
        carryPicker.onBacktab = { [weak self] in self?.moveTab(-1) }
        carryPicker.onFocusLost = { [weak self] in self?.focus(self?.addVarButton) }
        let carryGroup = Self.vStack(
            [caption("Copy into new worktrees", required: false), carryPicker], spacing: 6)

        let built = FormCard.content(
            rows: [headerRow, nameRow, tabsGroup, envGroup, carryGroup], footer: buildFooter(), spacing: 14)
        footerDivider = built.divider
        return built.view
    }

    private func buildNameRow() -> NSView {
        wireField(titleField)
        titleField.onChange = { [weak self] in self?.nameEdited() }
        titleField.onArrowRight = { [weak self] in self?.focus(self?.folderPicker.field.field) }
        let titleGroup = LabeledField(caption: caption("Workspace name", required: true), control: titleField)
        titleGroup.widthAnchor.constraint(equalToConstant: Self.nameWidth).isActive = true
        self.titleGroup = titleGroup

        wireField(folderPicker.field)
        folderPicker.onPicked = { [weak self] _ in self?.folderChanged() }
        folderPicker.field.onChange = { [weak self] in self?.folderChanged() }
        folderPicker.wireNav(
            onVertical: { [weak self] in self?.moveVertical($0) },
            onTabForward: { [weak self] in self?.moveTab(1) })
        folderPicker.field.onArrowLeft = { [weak self] in self?.focus(self?.titleField.field) }
        let folderGroup = LabeledField(caption: caption("Folder", required: true), control: folderPicker)
        folderGroup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.folderGroup = folderGroup

        let row = NSStackView(views: [titleGroup, folderGroup])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = 12
        return row
    }

    private func buildTabsGroup() -> NSView {
        tabStrip.onSelect = { [weak self] index in self?.selectTab(index) }
        tabStrip.onAdd = { [weak self] in self?.addTab() }
        tabStrip.onRemove = { [weak self] index in self?.removeTab(at: index, focusingStrip: true) }
        tabStrip.onRename = { [weak self] index, name in
            self?.form.renameTab(at: index, to: name)
            self?.tabsChanged()
        }
        tabStrip.onMove = { [weak self] from, to in
            self?.form.moveTab(at: from, to: to)
            self?.tabsChanged()
        }
        tabStrip.onArrowUp = { [weak self] in self?.drawing.focus(.bottom) }
        tabStrip.onArrowDown = { [weak self] in self?.moveVertical(1) }
        tabStrip.onTab = { [weak self] in self?.moveTab(1) }
        tabStrip.onBacktab = { [weak self] in self?.moveTab(-1) }

        drawing.onCommandChanged = { [weak self] region, text in
            guard let self else { return }
            self.form.setCommand(text, in: region, ofTab: self.form.selected)
            self.renderTabs()
            self.refreshValidity()
        }
        drawing.onDrawerClosed = { [weak self] _ in
            guard let self else { return }
            if let message = self.form.repairLaunchFocus() { self.showNotice(message, undoable: false) }
            self.renderTabs()
        }
        drawing.onOpenFocused = { [weak self] region in
            guard let self, self.form.setLaunchFocus(region, inTab: self.form.selected) else { return }
            self.renderTabs()
        }
        drawing.onExitUp = { [weak self] in self?.moveVertical(-1) }
        drawing.onExitDown = { [weak self] in self?.moveVertical(1) }
        drawing.onTab = { [weak self] in self?.moveTab(1) }
        drawing.onBacktab = { [weak self] in self?.moveTab(-1) }

        let stack = Self.vStack([drawing, tabStrip], spacing: 10)
        let group = LabeledField(caption: caption("Tabs", required: false), control: stack)
        tabsGroup = group
        return group
    }

    private func buildFooter() -> NSView {
        notice.font = .systemFont(ofSize: 12)
        notice.textColor = Theme.current.chrome.ink(.subtle)
        notice.lineBreakMode = .byTruncatingTail
        notice.maximumNumberOfLines = 1
        notice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        notice.isHidden = true
        undoButton.isHidden = true
        undoButton.onTap = { [weak self] in self?.undoRemoval() }

        cancelButton.onTap = { [weak self] in self?.onCancel() }
        addButton.setTitle(editingWorkspace == nil ? "Add Workspace" : "Save")
        addButton.onTap = { [weak self] in self?.submit() }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [notice, undoButton, spacer, cancelButton, addButton]
        if onDelete != nil {
            deleteButton.onTap = { [weak self] in self?.onDelete?() }
            views.insert(deleteButton, at: 0)
        }
        for button in [addVarButton, undoButton, cancelButton, addButton, deleteButton] {
            button.isKeyboardFocusable = true
            button.onArrowUp = { [weak self] in self?.moveVertical(-1) }
            button.onArrowDown = { [weak self] in self?.moveVertical(1) }
            button.onTab = { [weak self] in self?.moveTab(1) }
            button.onBacktab = { [weak self] in self?.moveTab(-1) }
        }
        wireFooterArrows()
        return Self.hStack(views, spacing: 8)
    }

    private func wireFooterArrows() {
        var chain: [AppButton] = []
        if onDelete != nil { chain.append(deleteButton) }
        if !undoButton.isHidden { chain.append(undoButton) }
        chain += [cancelButton, addButton]
        for (index, button) in chain.enumerated() {
            let previous = index > 0 ? chain[index - 1] : nil
            let next = index + 1 < chain.count ? chain[index + 1] : nil
            button.onArrowLeft = previous.map { target in { [weak self] in self?.focus(target) } }
            button.onArrowRight = next.map { target in { [weak self] in self?.focus(target) } }
        }
    }

    private func renderTabs() {
        tabStrip.render(form)
        let focus = form.launchFocus
        drawing.render(
            tab: form.selectedTab, index: form.selected, opensFocusedIn: focus.tab == form.selected ? focus.region : nil
        )
    }

    private func tabsChanged() {
        showNotice(nil, undoable: false)
        renderTabs()
        refreshValidity()
    }

    private func showNotice(_ text: String?, undoable: Bool) {
        notice.stringValue = text ?? ""
        notice.isHidden = text == nil
        let showsUndo = text != nil && undoable && form.lastRemoval != nil
        if undoButton.isHidden == showsUndo {
            undoButton.isHidden = !showsUndo
            wireFooterArrows()
        }
    }

    private var isStripFocused: Bool { tabStrip.chips.contains { isFocused($0) } }

    private var focusSpot: FocusSpot {
        if isStripFocused { return .chip }
        if let region = drawing.focusedRegion { return .region(region) }
        if let rail = Workspace.Region.allCases.first(where: { drawing.rail($0).map(isFocused) == true }) {
            return .region(rail)
        }
        return .elsewhere
    }

    private func restore(_ spot: FocusSpot) {
        layoutSubtreeIfNeeded()
        switch spot {
        case .chip: tabStrip.focusSelectedChip()
        case .region(let region): drawing.focus(region)
        case .elsewhere: break
        }
    }

    private func selectTab(_ index: Int) {
        guard form.tabs.indices.contains(index) else { return }
        let spot = focusSpot
        form.select(index)
        renderTabs()
        if case .region = spot { restore(spot) }
    }

    private func selectTab(cycling delta: Int) {
        let count = form.tabs.count
        guard count > 1 else { return }
        let spot = focusSpot
        form.select((form.selected + delta + count) % count)
        renderTabs()
        restore(spot)
    }

    private func addTab() {
        form.addTab()
        tabsChanged()
        layoutSubtreeIfNeeded()
        drawing.focus(.main)
    }

    private func removeTab(at index: Int, focusingStrip: Bool) {
        guard let message = form.removeTab(at: index) else { return }
        showNotice(message, undoable: true)
        renderTabs()
        refreshValidity()
        restore(focusingStrip ? .chip : .region(.main))
    }

    private func undoRemoval() {
        form.undoRemoval()
        showNotice(nil, undoable: false)
        renderTabs()
        refreshValidity()
        restore(.chip)
    }

    private func moveSelectedTab(by delta: Int) {
        let spot = focusSpot
        form.moveTab(at: form.selected, to: form.selected + delta)
        tabsChanged()
        if case .chip = spot { restore(spot) }
    }

    private func verticalStops() -> [NSView] {
        var stops: [NSView] = [titleField.field, folderPicker.field.field]
        if let main = drawing.stop(for: .main) { stops.append(main) }
        if let chip = tabStrip.selectedChip { stops.append(chip) }
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
        if isStripFocused { return tabStrip.selectedChip }
        if case .region = focusSpot { return drawing.stop(for: .main) }
        for row in envRows where isFocused(row.valueBox.field) || isFocused(row.removeButton) {
            return row.keyBox.field
        }
        if isFocused(folderPicker.chooseButton) { return folderPicker.field.field }
        if isFocused(cancelButton) || isFocused(deleteButton) || isFocused(undoButton) { return addButton }
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
        if window?.makeFirstResponder(row.keyBox.field) == true {
            layoutSubtreeIfNeeded()
            KeyboardFocus.reveal(row, among: verticalStops(), travelling: .down)
        }
        refreshValidity()
        return row
    }

    private func removeEnvRow(_ row: EnvRow) {
        envRows.removeAll { $0 === row }
        envStack.removeArrangedSubview(row)
        row.removeFromSuperview()
        window?.makeFirstResponder(addVarButton)
        refreshValidity()
    }

    private func prefill() {
        guard let ws = editingWorkspace else { return }
        titleField.setText(ws.title)
        folderPicker.setText(PathDisplay.abbreviatingHome(ws.path.path))
        refreshNamePlaceholder()
        for key in ws.env.keys.sorted() {
            let row = addEnvRow()
            row.keyBox.setText(key)
            row.valueBox.setText(ws.env[key] ?? "")
        }
        carryPicker.setCarried(ws.carry)
        carryPicker.workspaceFolder = ws.path
    }

    private func focus(_ view: NSView?) {
        guard let view else { return }
        window?.makeFirstResponder(view)
    }

    private var folderName: String { WorkspaceForm.folderName(folderPicker.text) }

    private var typedTitle: String { titleField.text.trimmingCharacters(in: .whitespaces) }

    private var effectiveTitle: String { typedTitle.isEmpty ? folderName : typedTitle }

    private func nameEdited() {
        form.nameEdited(titleField.text)
        refreshNamePlaceholder()
        refreshValidity()
    }

    private func folderChanged() {
        if form.nameFollowsFolder { titleField.setText(folderName) }
        refreshNamePlaceholder()
        carryPicker.workspaceFolder = resolvedFolder().flatMap { PathDisplay.isDirectory($0) ? $0 : nil }
        refreshValidity()
    }

    private func refreshNamePlaceholder() {
        let placeholder = folderName.isEmpty ? Self.namePlaceholder : folderName
        guard titleField.placeholder != placeholder else { return }
        titleField.setPlaceholder(placeholder)
    }

    private func submit() {
        if let problem = validate(includeRequired: true) {
            reveal(problem)
            return
        }
        guard let workspace = buildWorkspace() else { return }
        onSubmit(workspace)
    }

    private func reveal(_ problem: Problem) {
        switch problem {
        case .view(let view):
            focus(view)
        case .tabName(let index):
            form.select(index)
            renderTabs()
            layoutSubtreeIfNeeded()
            tabStrip.focusSelectedChip()
        case .command(let index, let region):
            form.select(index)
            renderTabs()
            layoutSubtreeIfNeeded()
            drawing.focus(region)
        }
    }

    private func buildWorkspace() -> Workspace? {
        let title = effectiveTitle
        guard !title.isEmpty, let folder = resolvedFolder() else { return nil }
        var env: [String: String] = [:]
        for row in envRows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            env[key] = row.value.trimmingCharacters(in: .whitespaces)
        }
        let built = form.build()
        return Workspace(
            title: title, path: folder, tabs: built.tabs, focus: built.focus, env: env, carry: carryPicker.carried)
    }

    private func resolvedFolder() -> URL? {
        let text = folderPicker.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return URL(fileURLWithPath: PathDisplay.expandingHome(text), isDirectory: true)
    }

    /// Rejects `=` and `"` where they cannot round-trip: the format has no escaping.
    @discardableResult
    private func validate(includeRequired: Bool) -> Problem? {
        var first: Problem?
        func flag(_ group: LabeledField?, field: NSView, _ message: String?) {
            group?.setMessage(message)
            if message != nil, first == nil { first = .view(field) }
        }

        let title = effectiveTitle
        var titleMessage: String?
        if !typedTitle.isEmpty, typedTitle.contains(where: { "[]#\"".contains($0) }) {
            titleMessage = "Can't contain [ ] # or \"."
        } else if !title.isEmpty, existingTitles.contains(title) {
            titleMessage = "A workspace named \(title) already exists."
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

        let tabProblem = validateTabs()
        if first == nil { first = tabProblem }

        func keyIsBad(_ row: EnvRow) -> Bool { row.key.contains("=") || row.key.contains("\"") }
        let badEnvRow = envRows.first { keyIsBad($0) || $0.value.contains("\"") }
        envError.stringValue =
            badEnvRow == nil ? "" : "Names can't use = or \" and values can't use \"."
        envError.isHidden = (badEnvRow == nil)
        if let badEnvRow, first == nil {
            first = .view(keyIsBad(badEnvRow) ? badEnvRow.keyBox.field : badEnvRow.valueBox.field)
        }

        return first
    }

    private func validateTabs() -> Problem? {
        var first: Problem?
        var messages: [String] = []
        if let index = form.tabs.firstIndex(where: { $0.name?.contains("\"") == true }) {
            messages.append("Tab names can't contain a \" character.")
            first = .tabName(index)
        }
        let badCommand = form.tabs.indices.lazy.compactMap { index in
            Workspace.Region.allCases.first { self.form.tabs[index].command(in: $0)?.contains("\"") == true }
                .map { (index, $0) }
        }.first
        if let (index, region) = badCommand {
            messages.append("Commands can't contain a \" character.")
            if first == nil { first = .command(index, region) }
        }
        tabsGroup?.setMessage(messages.isEmpty ? nil : messages.joined(separator: " "))
        return first
    }

    private func refreshValidity() { validate(includeRequired: false) }

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
