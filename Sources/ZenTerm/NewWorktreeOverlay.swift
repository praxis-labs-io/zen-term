import AppKit

/// The create-a-worktree card, opened with ⌥⏎ over a ⌘P picker row. It collects a branch name and
/// a base, hands them to `onSubmit`, and holds the card through the create so a long `carry` copy
/// has somewhere to show. A `ModalOverlay` built on the same card, backdrop and spring as
/// `AddWorkspaceOverlay`, whose keyboard model it mirrors: Up/Down between stops, ⌘Return submits.
final class NewWorktreeOverlay: NSView, ModalOverlay {
    private let workspace: Workspace
    private let options: WorktreeStore.CreateOptions
    private let onSubmit: (String, WorktreeStore.Base) -> Void
    private let onCancel: () -> Void

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

    /// True from submit until create answers. Locks the branch field, both buttons, Esc and the
    /// backdrop: `WorktreeStore.create` cannot be called back, so tearing the card down early would
    /// leave a worktree landing with nothing to report to.
    private var isWorking = false

    init(
        workspace: Workspace, options: WorktreeStore.CreateOptions, background: NSColor,
        onSubmit: @escaping (String, WorktreeStore.Base) -> Void, onCancel: @escaping () -> Void
    ) {
        self.workspace = workspace
        self.options = options
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let backdrop = BackdropView(onClick: { [weak self] in self?.cancel() })
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

    /// The card owns Esc, the same way `AddWorkspaceOverlay` does: a focused button lets it bubble
    /// here and a focused field routes it through the field editor, which never bubbles as a
    /// card-root `keyDown`. A create in flight counts as dismissing, so Esc does nothing.
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

    /// Lock the card for the create and say what it is on. The host calls this on submit and
    /// resolves it by closing the card on success or calling `failWork` on failure.
    func beginWork(_ phase: String) {
        isWorking = true
        errorLabel.isHidden = true
        phaseGroup.isHidden = false
        spinner.isSpinning = true
        setPhase(phase)
        branchField.field.isEditable = false
        cancelButton.isEnabled = false
        createButton.isEnabled = false
    }

    /// Name the step running now. The create is two steps and the carry names its entries, so this
    /// reports what is happening rather than standing in for it.
    func setPhase(_ phase: String) {
        phaseLabel.stringValue = phase
    }

    /// Hand the card back with the reason the create failed.
    func failWork(_ message: String) {
        isWorking = false
        phaseGroup.isHidden = true
        spinner.isSpinning = false
        branchField.field.isEditable = true
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
        // The phase line takes the footer's dead space, so a create that runs for seconds says so
        // without the card changing height under the person waiting on it.
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

    /// Cancel shares the footer's vertical stop with Create; it is reached with Left/Right.
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

    /// Name the ref if git answered, and say which one it is otherwise. Naming it is the whole
    /// point: a caption that only says "the default branch" makes the reader go and look.
    private static func startsFrom(_ ref: String?, _ fallback: String) -> String {
        "Starts from \(ref ?? fallback)."
    }

    private func cancel() {
        guard !isWorking else { return }
        onCancel()
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

    /// Update the branch field's inline message and return it when it offends, nil when
    /// submittable. `includeRequired` gates the empty check: false for the live pass, so an
    /// untouched field is not flagged, true on a submit attempt.
    @discardableResult
    private func validate(includeRequired: Bool) -> NSView? {
        let branch = branchName
        var message: String?
        // The dash is git's own defect, not a style rule: `worktree add -b -m` hands `-m` to git's
        // `git branch`, which has no `--` guard, and the repo's checked-out branch gets renamed.
        if branch.hasPrefix("-") {
            message = "Can't start with a dash."
        } else if branch.contains(where: \.isWhitespace) {
            message = "Can't contain spaces."
        } else if options.branches.contains(branch) {
            message = "That branch already exists."
        } else if includeRequired, branch.isEmpty {
            message = "Enter a branch name."
        }
        branchGroup?.setMessage(message)
        return message == nil ? nil : branchField.field
    }

    private func refreshValidity() { validate(includeRequired: false) }

    // MARK: layout helpers

    /// A caption built straight into a stack, retained so `reapplyTheme()` can reach it. The ones
    /// wrapped by a `LabeledField` need no retaining: it holds its own.
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
