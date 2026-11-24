import AppKit

final class NewWorktreeOverlay: ModalShell, ModalOverlay {
    static let width: CGFloat = 460

    private struct Inputs: Equatable {
        let branch: String
        let base: Int
    }

    private let workspace: Workspace
    private let options: WorktreeStore.CreateOptions
    private let onSubmit: (Request) -> Void
    private let onEditWorkspace: (() -> Void)?

    private let header = ModalHeader(title: "New Worktree")

    private let branchField = BranchField()
    private var branchGroup: LabeledField?
    private var baseGroup: NSStackView?

    private let baseSegment = SegmentedControl(
        options: ["Default branch", "This checkout"], selectedIndex: 0
    ) { _ in }
    private let baseCaption = NSTextField(labelWithString: "")
    private let branchCaption = NSTextField(labelWithString: "")
    private let carryLabel = NSTextField(labelWithString: "")
    private let carryLink = AppButton(title: "Choose what to copy", variant: .muted)
    private let errorLabel = FormErrorLabel(maximumLines: 3)
    private let spinner = Spinner()
    private let phaseLabel = NSTextField(labelWithString: "")
    private let phaseGroup = NSStackView()

    private let cancelButton = AppButton(title: "Cancel", variant: .secondary)
    private let createButton = ModalShell.submitButton(title: "Create Worktree")

    private var isWorking = false
    private var openingInputs: Inputs?

    init(
        workspace: Workspace, options: WorktreeStore.CreateOptions,
        onSubmit: @escaping (Request) -> Void, onCancel: @escaping () -> Void,
        onDismiss: @escaping () -> Void, onEditWorkspace: (() -> Void)? = nil
    ) {
        self.workspace = workspace
        self.options = options
        self.onSubmit = onSubmit
        self.onEditWorkspace = onEditWorkspace
        super.init(width: Self.width, onCancel: onCancel, onDismiss: onDismiss)
        card.heightAnchor.constraint(lessThanOrEqualToConstant: FormCard.maxHeight).isActive = true
        embed(buildContent())
        baseChanged(baseSegment.selectedIndex)
        openingInputs = inputs
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // `WorktreeStore.create` can't be cancelled, so Esc and the backdrop lock while it runs.
    override var isBusy: Bool { isWorking }

    override var hasUnsavedChanges: Bool { inputs != openingInputs }

    private var inputs: Inputs { Inputs(branch: branchField.text, base: baseSegment.selectedIndex) }

    func owns(_ chord: Chord) -> Bool { chord == Self.submitChord }

    func focusInitialResponder() { focus(branchField.field) }

    override func reapplyTheme() {
        super.reapplyTheme()
        let chrome = Theme.current.chrome
        baseCaption.textColor = chrome.ink(.muted)
        branchCaption.textColor = chrome.ink(.muted)
        carryLabel.textColor = chrome.ink(.muted)
        phaseLabel.textColor = chrome.ink(.muted)
    }

    func beginWork(_ phase: String) {
        isWorking = true
        errorLabel.clear()
        phaseGroup.isHidden = false
        spinner.isSpinning = true
        setPhase(phase)
        branchField.field.isEditable = false
        baseSegment.isEnabled = false
        carryLink.isEnabled = false
        cancelButton.isEnabled = false
        createButton.isEnabled = false
    }

    func setPhase(_ phase: String) {
        phaseLabel.stringValue = phase
    }

    func failWork(_ message: String) {
        isWorking = false
        phaseGroup.isHidden = true
        spinner.isSpinning = false
        branchField.field.isEditable = true
        baseSegment.isEnabled = true
        carryLink.isEnabled = true
        cancelButton.isEnabled = true
        createButton.isEnabled = true
        errorLabel.show(message)
        window?.makeFirstResponder(branchField.field)
    }

    private func buildContent() -> NSStackView {
        wireBranchField()
        let branchGroup = LabeledField(
            caption: SectionCaption("Branch", required: true), control: branchField)
        self.branchGroup = branchGroup
        branchCaption.font = ChromeType.font(.caption)
        branchCaption.textColor = Theme.current.chrome.ink(.muted)
        branchCaption.lineBreakMode = .byWordWrapping
        branchCaption.maximumNumberOfLines = 0
        branchCaption.isHidden = true
        let branchStack = Self.vStack([branchGroup, branchCaption], spacing: ChromeMetrics.Spacing.s6)

        baseSegment.onChange = { [weak self] index in self?.baseChanged(index) }
        wireSegment(baseSegment)
        baseCaption.font = ChromeType.font(.caption)
        baseCaption.textColor = Theme.current.chrome.ink(.muted)
        let baseRow = NSStackView.huggingRow(baseSegment)
        let baseGroup = Self.vStack(
            [SectionCaption("Base"), baseRow, baseCaption], spacing: ChromeMetrics.Spacing.s6)
        self.baseGroup = baseGroup

        carryLabel.font = ChromeType.font(.caption)
        carryLabel.textColor = Theme.current.chrome.ink(.muted)
        carryLabel.lineBreakMode = .byTruncatingTail
        carryLabel.stringValue = workspace.carry.joined(separator: ", ")
        carryLabel.isHidden = workspace.carry.isEmpty
        carryLink.setTitle(workspace.carry.isEmpty ? "Choose what to copy" : "Change what to copy")
        carryLink.isHidden = onEditWorkspace == nil
        carryLink.isKeyboardFocusable = onEditWorkspace != nil
        carryLink.onTap = { [weak self] in self?.editWorkspace() }
        carryLink.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        carryLink.onArrowDown = { [weak self] in self?.moveVertical(1) }
        carryLink.onTab = { [weak self] in self?.moveTab(1) }
        carryLink.onBacktab = { [weak self] in self?.moveTab(-1) }
        let carryGroup = Self.vStack(
            [SectionCaption("Copy into this worktree"), carryLabel, Self.leadingWrap(carryLink)],
            spacing: ChromeMetrics.Spacing.s6)

        phaseLabel.font = ChromeType.font(.caption)
        phaseLabel.textColor = Theme.current.chrome.ink(.muted)
        phaseLabel.lineBreakMode = .byTruncatingTail
        phaseGroup.orientation = .horizontal
        phaseGroup.alignment = .centerY
        phaseGroup.spacing = ChromeMetrics.Spacing.s6
        phaseGroup.setViews([spinner, phaseLabel], in: .leading)
        phaseGroup.isHidden = true

        cancelButton.onTap = { [weak self] in self?.cancelDiscardingChanges() }
        createButton.onTap = { [weak self] in self?.submit() }
        for button in [cancelButton, createButton] {
            button.isKeyboardFocusable = true
            button.onArrowUp = { [weak self] in self?.moveVertical(-1) }
            button.onArrowDown = { [weak self] in self?.moveVertical(1) }
        }
        createButton.onArrowLeft = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onArrowRight = { [weak self] in self?.focus(self?.createButton) }
        createButton.onTab = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onBacktab = { [weak self] in self?.focus(self?.createButton) }
        cancelButton.onTab = { [weak self] in self?.moveTab(1) }
        createButton.onBacktab = { [weak self] in self?.moveTab(-1) }
        let actionBar = ModalActionBar(leading: [phaseGroup], trailing: [cancelButton, createButton])

        return FormCard.content(
            rows: [header, branchStack, baseGroup, carryGroup],
            footer: FormCard.footer(actionBar, failure: errorLabel), spacing: ChromeMetrics.Spacing.modalSectionGap)
    }

    private func verticalStops() -> [NSView] {
        var stops: [NSView] = [branchField.field]
        if !(baseGroup?.isHidden ?? false) { stops.append(baseSegment) }
        if carryLink.isKeyboardFocusable { stops.append(carryLink) }
        stops.append(createButton)
        return stops
    }

    private func moveVertical(_ delta: Int) {
        step(delta, wrap: false)
    }

    private func moveTab(_ delta: Int) {
        step(delta, wrap: true)
    }

    private func step(_ delta: Int, wrap: Bool) {
        let stops = verticalStops()
        let anchor = currentVerticalAnchor(in: stops).flatMap { anchor in
            stops.firstIndex { $0 === anchor }
        }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta, wrap: wrap) {
            FormCard.revealTarget(for: $0)
        }
    }

    private func currentVerticalAnchor(in stops: [NSView]) -> NSView? {
        if let direct = stops.first(where: isFocused) { return direct }
        return isFocused(cancelButton) ? createButton : nil
    }

    private func isFocused(_ view: NSView) -> Bool { KeyboardFocus.isFocused(view, in: window) }

    private func wireBranchField() {
        branchField.onChange = { [weak self] in self?.refreshValidity() }
        branchField.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        branchField.onArrowDown = { [weak self] in self?.moveVertical(1) }
        branchField.onEnter = { [weak self] in self?.moveVertical(1) }
        branchField.onTab = { [weak self] in self?.moveTab(1) }
        branchField.onBacktab = { [weak self] in self?.moveTab(-1) }
        branchField.onSubmit = { [weak self] in self?.submit() }
        branchField.setBranches(options.branches, notes: options.holders.mapValues(Self.branchNote))
    }

    static func branchNote(for holder: WorktreeStore.Holder) -> String {
        switch holder {
        case .worktree: return "has a worktree"
        case .mainCheckout: return "main checkout"
        }
    }

    private func wireSegment(_ segment: SegmentedControl) {
        segment.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        segment.onArrowDown = { [weak self] in self?.moveVertical(1) }
        segment.onTab = { [weak self] in self?.moveTab(1) }
        segment.onBacktab = { [weak self] in self?.moveTab(-1) }
    }

    private func baseChanged(_ index: Int) {
        baseCaption.stringValue =
            index == 1
            ? Self.startsFrom(options.currentBranch, "this checkout")
            : Self.startsFrom(options.defaultBase, "the default branch")
    }

    private static func startsFrom(_ ref: String?, _ fallback: String) -> String {
        "Starts from \(ref ?? fallback)."
    }

    private func submit() {
        guard !isWorking, !confirm.isShowing else { return }
        branchField.closeList()
        let validation = validate(submitting: true)
        guard validation.isValid else { return validation.revealFirstInvalid() }
        onSubmit(request)
    }

    static func moveMainCheckoutMessage(_ branch: String, to base: String) -> String {
        let local = base.hasPrefix("origin/") ? String(base.dropFirst("origin/".count)) : base
        return """
            \(branch) is checked out in your main checkout. Creating this worktree moves that \
            checkout to \(local), so any shell open there will be on \(local).
            """
    }

    enum Request: Equatable {
        case newBranch(String, WorktreeStore.Base)
        case existingBranch(String)
    }

    var branchName: String { branchField.text.trimmingCharacters(in: .whitespaces) }

    #if DEBUG
        func setBranchForTesting(_ branch: String) {
            branchField.box.setText(branch)
            refreshValidity()
        }
    #endif

    var isExistingBranch: Bool { options.branches.contains(branchName) }

    /// `defaultBase` is a remote ref and checking one out detaches HEAD, so this is the local name.
    private var localDefaultBranch: String? {
        guard let base = options.defaultBase else { return nil }
        return base.hasPrefix("origin/") ? String(base.dropFirst("origin/".count)) : base
    }

    var request: Request {
        isExistingBranch ? .existingBranch(branchName) : .newBranch(branchName, base)
    }

    var base: WorktreeStore.Base {
        baseSegment.selectedIndex == 1 ? .currentCheckout : .defaultBranch
    }

    /// Refuses a leading `-`: `worktree add -b -m` hands it to `git branch`, which renames the checked-out branch.
    @discardableResult
    private func validate(submitting: Bool) -> FormValidation {
        let branch = branchName
        var message: String?
        if branch.hasPrefix("-") {
            message = "Can't start with a dash."
        } else if branch.contains(where: \.isWhitespace) {
            message = "Can't contain spaces."
        } else if isExistingBranch {
            if case .worktree = options.holders[branch] {
                message = "\(branch) already has a worktree."
            } else if case .mainCheckout = options.holders[branch], branch == localDefaultBranch {
                message = "\(branch) is the default branch, so your main checkout cannot move off it."
            }
        } else if let nested = options.branches.filter({ $0.hasPrefix(branch + "/") }).min() {
            message = "\(nested) already uses this name as a folder."
        } else if let parent = Self.branchAncestor(of: branch, in: options.branches) {
            message = "\(parent) is already a branch, so this can't be a folder."
        } else if submitting, branch.isEmpty {
            message = "Enter a branch name."
        }
        var validation = FormValidation()
        validation.flag(branchGroup, message, at: branchField.field)
        renderBranchMode()
        return validation
    }

    private func renderBranchMode() {
        let existing = isExistingBranch
        let moved = baseGroup?.isHidden != existing
        baseGroup?.isHidden = existing
        if moved {
            card.layoutSubtreeIfNeeded()
            branchField.repositionList()
        }
        guard existing else {
            branchCaption.isHidden = true
            return
        }
        branchCaption.isHidden = false
        if case .mainCheckout = options.holders[branchName] {
            branchCaption.stringValue = Self.moveMainCheckoutMessage(
                branchName, to: options.defaultBase ?? "the default branch")
        } else {
            branchCaption.stringValue = "Uses the existing branch \(branchName)."
        }
    }

    /// Git keeps a ref in a file, so `a` and `a/b` can't both be branches.
    private static func branchAncestor(of branch: String, in branches: Set<String>) -> String? {
        var prefix = ""
        for part in branch.split(separator: "/").dropLast() {
            prefix += prefix.isEmpty ? String(part) : "/\(part)"
            if branches.contains(prefix) { return prefix }
        }
        return nil
    }

    private func refreshValidity() {
        errorLabel.clear()
        validate(submitting: false)
    }

    private func editWorkspace() {
        guard !isWorking else { return }
        onEditWorkspace?()
    }

    private static func leadingWrap(_ view: NSView) -> NSView {
        let stack = NSStackView(views: [view])
        stack.orientation = .horizontal
        stack.alignment = .centerY
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
