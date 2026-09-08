import AppKit

/// The create-a-worktree card, opened with ⌥⏎ over a ⌘P picker row. Mirrors
/// `AddWorkspaceOverlay`'s card, keyboard model and validation shape.
final class NewWorktreeOverlay: NSView, ModalOverlay {
    private let workspace: Workspace
    private let options: WorktreeStore.CreateOptions
    private let onSubmit: (String, WorktreeStore.Base) -> Void
    private let onCancel: () -> Void
    private let onDismiss: () -> Void

    private let card = CardView()
    private var dismiss = DismissGate()
    private let header = NSTextField(labelWithString: "")

    private let branchField = FieldBox(placeholder: "feature/name")
    private var branchGroup: LabeledField?

    private let baseSegment = SegmentedControl(
        options: ["Default branch", "This checkout"], selectedIndex: 0
    ) { _ in }
    private let baseCaption = NSTextField(labelWithString: "")
    private let carryLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let spinner = Spinner()
    private let phaseLabel = NSTextField(labelWithString: "")
    private let phaseGroup = NSStackView()

    private var captions: [FieldCaption] = []
    private let cancelButton = AppButton(title: "Cancel", variant: .secondary)
    private let createButton = AppButton(
        title: "Create Worktree", variant: .primary, keyEquivalent: "\r",
        keyEquivalentModifierMask: .command)

    /// `WorktreeStore.create` cannot be called back, so Esc and the backdrop are locked too: a
    /// card torn down early leaves a worktree landing with nothing to report to.
    private var isWorking = false

    init(
        workspace: Workspace, options: WorktreeStore.CreateOptions, background: NSColor,
        onSubmit: @escaping (String, WorktreeStore.Base) -> Void, onCancel: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.workspace = workspace
        self.options = options
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Clicking out is a way out, not a way back: Esc and Cancel return to the list, this does
        // not. The picker's own backdrop dismisses to the terminal too.
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

            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        baseChanged(baseSegment.selectedIndex)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: ModalOverlay

    func focusInitialResponder() { window?.makeFirstResponder(branchField.field) }

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

    /// The card root is the single Esc owner, for the reasons `AddWorkspaceOverlay` documents.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
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
        carryLabel.textColor = chrome.ink(.muted)
        phaseLabel.textColor = chrome.ink(.muted)
        errorLabel.textColor = chrome.destructive.nsColor
        spinner.reapplyTheme()

        let controls: [ThemeReapplying] = [branchField, baseSegment, cancelButton, createButton]
        controls.forEach { $0.reapplyTheme() }
        branchGroup?.reapplyTheme()
        captions.forEach { $0.reapplyTheme() }
    }

    // MARK: the create's own state

    /// The host resolves this by closing the card, or by calling `failWork`.
    func beginWork(_ phase: String) {
        isWorking = true
        errorLabel.isHidden = true
        phaseGroup.isHidden = false
        spinner.isSpinning = true
        setPhase(phase)
        branchField.field.isEditable = false
        baseSegment.isEnabled = false
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
        cancelButton.isEnabled = true
        createButton.isEnabled = true
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        window?.makeFirstResponder(branchField.field)
    }

    // MARK: content

    private func buildContent() -> NSStackView {
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = Theme.current.chrome.foreground.nsColor
        header.stringValue = "New Worktree"

        wireField(branchField)
        let branchGroup = LabeledField(
            caption: FieldCaption("BRANCH", required: true), control: branchField)
        self.branchGroup = branchGroup

        baseSegment.onChange = { [weak self] index in self?.baseChanged(index) }
        wireSegment(baseSegment)
        baseCaption.font = .systemFont(ofSize: 11)
        baseCaption.textColor = Theme.current.chrome.ink(.muted)
        let baseGroup = Self.vStack(
            [caption("BASE"), baseSegment, baseCaption], spacing: 6)

        carryLabel.font = .systemFont(ofSize: 11)
        carryLabel.textColor = Theme.current.chrome.ink(.muted)
        carryLabel.lineBreakMode = .byTruncatingTail
        carryLabel.stringValue =
            workspace.carry.isEmpty
            ? "Nothing set. Add carry lines to this workspace to bring over what git ignores."
            : workspace.carry.joined(separator: ", ")
        let carryGroup = Self.vStack([caption("CARRY"), carryLabel], spacing: 6)

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
        // In the footer's dead space, so a long create says so without the card changing height.
        let footer = Self.hStack([phaseGroup, spacer, cancelButton, createButton], spacing: 8)

        let content = NSStackView(views: [
            header, branchGroup, baseGroup, carryGroup, errorLabel, footer,
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

    // MARK: keyboard

    private func verticalStops() -> [NSView] {
        [branchField.field, baseSegment, createButton]
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
        guard
            let next = KeyboardFocus.step(
                from: anchor, delta: delta, count: stops.count, wrap: wrap)
        else { return }
        window?.makeFirstResponder(stops[next])
    }

    /// Cancel shares Create's stop; it is reached with Left/Right.
    private func currentVerticalAnchor(in stops: [NSView]) -> NSView? {
        if let direct = stops.first(where: isFocused) { return direct }
        return isFocused(cancelButton) ? createButton : nil
    }

    private func isFocused(_ view: NSView) -> Bool { KeyboardFocus.isFocused(view, in: window) }

    private func focus(_ view: NSView?) {
        guard let view else { return }
        window?.makeFirstResponder(view)
    }

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
        guard !isWorking else { return }
        if let firstInvalid = validate(includeRequired: true) {
            window?.makeFirstResponder(firstInvalid)
            return
        }
        onSubmit(branchName, base)
    }

    // MARK: model + validation

    var branchName: String { branchField.text.trimmingCharacters(in: .whitespaces) }

    var base: WorktreeStore.Base {
        baseSegment.selectedIndex == 1 ? .currentCheckout : .defaultBranch
    }

    /// `includeRequired` is false for the live pass, so an untouched field is not flagged.
    @discardableResult
    private func validate(includeRequired: Bool) -> NSView? {
        let branch = branchName
        var message: String?
        // `worktree add -b -m` hands `-m` to git's own `git branch`, which has no `--` guard, and
        // the repo's checked-out branch gets renamed.
        if branch.hasPrefix("-") {
            message = "Can't start with a dash."
        } else if branch.contains(where: \.isWhitespace) {
            message = "Can't contain spaces."
        } else if options.branches.contains(branch) {
            message = "That branch already exists."
        } else if let nested = options.branches.filter({ $0.hasPrefix(branch + "/") }).min() {
            message = "\(nested) already uses this name as a folder."
        } else if let parent = Self.branchAncestor(of: branch, in: options.branches) {
            message = "\(parent) is already a branch, so this can't be a folder."
        } else if includeRequired, branch.isEmpty {
            message = "Enter a branch name."
        }
        branchGroup?.setMessage(message)
        return message == nil ? nil : branchField.field
    }

    /// Git keeps a ref in a file, so `a` and `a/b` cannot both be branches. `min()` above picks the
    /// offender rather than any of them, so the message does not change between two identical runs.
    private static func branchAncestor(of branch: String, in branches: Set<String>) -> String? {
        var prefix = ""
        for part in branch.split(separator: "/").dropLast() {
            prefix += prefix.isEmpty ? String(part) : "/\(part)"
            if branches.contains(prefix) { return prefix }
        }
        return nil
    }

    private func refreshValidity() {
        // The message named a branch that is no longer in the field.
        errorLabel.isHidden = true
        validate(includeRequired: false)
    }

    // MARK: layout helpers

    /// Retained so `reapplyTheme()` can reach it. A `LabeledField` holds its own.
    private func caption(_ text: String) -> FieldCaption {
        let field = FieldCaption(text, required: false)
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
