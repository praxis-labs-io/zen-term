import AppKit

final class NewWorktreeOverlay: NSView, ModalOverlay {
    private let workspace: Workspace
    private let options: WorktreeStore.CreateOptions
    private let onSubmit: (Request) -> Void
    private let onCancel: () -> Void
    private let onDismiss: () -> Void
    private let onEditWorkspace: (() -> Void)?

    private let card = CardView()
    private var footerDivider: ThemeReapplying?
    private var dismiss = DismissGate()
    private lazy var confirm = ConfirmSlot(over: self)
    private let header = NSTextField(labelWithString: "")

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
    private let errorLabel = NSTextField(labelWithString: "")
    private let spinner = Spinner()
    private let phaseLabel = NSTextField(labelWithString: "")
    private let phaseGroup = NSStackView()

    private var captions: [FieldCaption] = []
    private let cancelButton = AppButton(title: "Cancel", variant: .secondary)
    private let createButton = AppButton(
        title: "Create Worktree", variant: .primary, keyEquivalent: "\r",
        keyEquivalentModifierMask: .command)

    /// `WorktreeStore.create` can't be cancelled, so Esc and the backdrop lock while it runs.
    private var isWorking = false

    init(
        workspace: Workspace, options: WorktreeStore.CreateOptions, background: NSColor,
        onSubmit: @escaping (Request) -> Void, onCancel: @escaping () -> Void,
        onDismiss: @escaping () -> Void, onEditWorkspace: (() -> Void)? = nil
    ) {
        self.workspace = workspace
        self.options = options
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.onDismiss = onDismiss
        self.onEditWorkspace = onEditWorkspace
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let backdrop = BackdropView(onClick: { [weak self] in self?.dismissToTerminal() })
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

        baseChanged(baseSegment.selectedIndex)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var isShowingOverlaidCard: Bool { confirm.isShowing }

    func focusInitialResponder() {
        if let card = confirm.card { card.focusInitialResponder() } else { focus(branchField.field) }
    }

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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if confirm.isShowing { return super.performKeyEquivalent(with: event) }
        if ModalEscape.handle(
            event, in: window, dismissing: dismiss.isDismissing || isWorking,
            close: { self.onCancel() })
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        CardChrome.reapplyTheme(to: card)
        header.textColor = chrome.foreground.nsColor
        baseCaption.textColor = chrome.ink(.muted)
        branchCaption.textColor = chrome.ink(.muted)
        confirm.card?.reapplyTheme()
        carryLabel.textColor = chrome.ink(.muted)
        phaseLabel.textColor = chrome.ink(.muted)
        errorLabel.textColor = chrome.destructive.nsColor
        spinner.reapplyTheme()
        footerDivider?.reapplyTheme()

        let controls: [ThemeReapplying] = [branchField, baseSegment, carryLink, cancelButton, createButton]
        controls.forEach { $0.reapplyTheme() }
        branchGroup?.reapplyTheme()
        captions.forEach { $0.reapplyTheme() }
    }

    func beginWork(_ phase: String) {
        isWorking = true
        errorLabel.isHidden = true
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
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        window?.makeFirstResponder(branchField.field)
    }

    private func buildContent() -> NSStackView {
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = Theme.current.chrome.foreground.nsColor
        header.stringValue = "New Worktree"

        wireBranchField()
        let branchGroup = LabeledField(
            caption: FieldCaption("BRANCH", required: true), control: branchField)
        self.branchGroup = branchGroup
        branchCaption.font = .systemFont(ofSize: 11)
        branchCaption.textColor = Theme.current.chrome.ink(.muted)
        branchCaption.lineBreakMode = .byWordWrapping
        branchCaption.maximumNumberOfLines = 2
        branchCaption.isHidden = true
        let branchStack = Self.vStack([branchGroup, branchCaption], spacing: 6)

        baseSegment.onChange = { [weak self] index in self?.baseChanged(index) }
        wireSegment(baseSegment)
        baseCaption.font = .systemFont(ofSize: 11)
        baseCaption.textColor = Theme.current.chrome.ink(.muted)
        let baseGroup = Self.vStack(
            [caption("BASE"), baseSegment, baseCaption], spacing: 6)
        self.baseGroup = baseGroup

        carryLabel.font = .systemFont(ofSize: 11)
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
            [caption("COPY INTO THIS WORKTREE"), carryLabel, Self.leadingWrap(carryLink)],
            spacing: 6)

        errorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        errorLabel.textColor = Theme.current.chrome.destructive.nsColor
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 3
        errorLabel.isHidden = true

        phaseLabel.font = .systemFont(ofSize: 11)
        phaseLabel.textColor = Theme.current.chrome.ink(.muted)
        phaseLabel.lineBreakMode = .byTruncatingTail
        phaseGroup.orientation = .horizontal
        phaseGroup.alignment = .centerY
        phaseGroup.spacing = 7
        phaseGroup.setViews([spinner, phaseLabel], in: .leading)
        phaseGroup.isHidden = true

        cancelButton.onTap = { [weak self] in self?.cancel() }
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
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = Self.hStack([phaseGroup, spacer, cancelButton, createButton], spacing: 8)

        let built = FormCard.content(
            rows: [header, branchStack, baseGroup, carryGroup, errorLabel],
            footer: footer, spacing: 14)
        footerDivider = built.divider
        return built.view
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

    private func focus(_ view: NSView?) {
        guard let view else { return }
        window?.makeFirstResponder(view)
    }

    private func wireBranchField() {
        branchField.onChange = { [weak self] in self?.refreshValidity() }
        branchField.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        branchField.onArrowDown = { [weak self] in self?.moveVertical(1) }
        branchField.onEnter = { [weak self] in self?.moveVertical(1) }
        branchField.onTab = { [weak self] in self?.moveTab(1) }
        branchField.onBacktab = { [weak self] in self?.moveTab(-1) }
        branchField.onSubmit = { [weak self] in self?.submit() }
        branchField.setBranches(options.branches, holders: options.holders)
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

    private func cancel() {
        guard !isWorking else { return }
        onCancel()
    }

    private func dismissToTerminal() {
        guard !isWorking else { return }
        onDismiss()
    }

    private func submit() {
        guard !isWorking, !confirm.isShowing else { return }
        branchField.closeList()
        if let firstInvalid = validate(includeRequired: true) {
            window?.makeFirstResponder(firstInvalid)
            return
        }
        guard case .mainCheckout = options.holders[branchName] else {
            onSubmit(request)
            return
        }
        confirm.present(
            ConfirmCard(
                title: "Move Your Main Checkout",
                message: Self.moveMainCheckoutMessage(
                    branchName, to: options.defaultBase ?? "the default branch"),
                confirmLabel: "Create Worktree",
                background: Theme.current.chrome.background.nsColor,
                onCancel: { [weak self] in
                    self?.confirm.dismiss { self?.focus(self?.branchField.field) }
                },
                onConfirm: { [weak self] in
                    guard let self else { return }
                    self.confirm.dismiss {}
                    self.onSubmit(self.request)
                }))
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
    private func validate(includeRequired: Bool) -> NSView? {
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
        } else if includeRequired, branch.isEmpty {
            message = "Enter a branch name."
        }
        branchGroup?.setMessage(message)
        renderBranchMode()
        return message == nil ? nil : branchField.field
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
            branchCaption.stringValue =
                "\(branchName) is checked out in your main checkout, which moves to the default branch."
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
        errorLabel.isHidden = true
        validate(includeRequired: false)
    }

    private func caption(_ text: String) -> FieldCaption {
        let field = FieldCaption(text, required: false)
        captions.append(field)
        return field
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
