import AppKit

/// The "Report an Issue" composer card, opened from the Help menu and the Settings nav. It collects
/// a title and a "what happened" description, shows the environment being sent (read-only), then
/// opens a prefilled GitHub new-issue in the browser via `onOpenURL` — the app has no backend, so the
/// browser files the report and a dragged-in diagnostics zip attaches the logs. A `ModalOverlay` like
/// `AddWorkspaceOverlay`, sharing its card + backdrop + spring and its keyboard model.
///
/// Fully keyboard-driven: Up/Down move between fields, Return in the title advances (in the text area
/// it inserts a newline), ⌘Return opens the issue, Esc cancels. Uses the pure `IssueReport` builder,
/// so the submit path is assertable by capturing the URL handed to `onOpenURL` (no real browser).
final class ReportIssueOverlay: NSView, ModalOverlay {
    private let report: SystemReport
    private let onOpenURL: (URL) -> Void
    private let onExportDiagnostics: () -> Void
    private let onCancel: () -> Void

    private let card = CardView()
    private var dismiss = DismissGate()

    /// Retained (not throwaway init-locals) so `reapplyTheme()` can recolor them in place — this form
    /// holds uncommitted typed values, so nothing here is ever rebuilt, only recolored.
    private let header = NSTextField(labelWithString: "")
    private let titleField = FieldBox(placeholder: "A short summary")
    private let whatHappened = TextAreaBox(placeholder: "What went wrong, and what you expected instead")
    private var titleGroup: LabeledField?
    private var whatGroup: LabeledField?
    private let envCaption = FieldCaption("ENVIRONMENT", required: false)
    private let envText = NSTextField(wrappingLabelWithString: "")
    private let envNote = NSTextField(labelWithString: "Sent with your report")

    private let exportButton = AppButton(title: "Export Diagnostics…", variant: .secondary)
    private let cancelButton = AppButton(title: "Cancel", variant: .secondary)
    private let openButton = AppButton(
        title: "Open on GitHub", variant: .primary, keyEquivalent: "\r", keyEquivalentModifierMask: .command)

    init(
        report: SystemReport, background: NSColor,
        onOpenURL: @escaping (URL) -> Void, onExportDiagnostics: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.report = report
        self.onOpenURL = onOpenURL
        self.onExportDiagnostics = onExportDiagnostics
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: ModalOverlay

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

    /// The card is the single Esc owner: a focused button lets Esc bubble here, a focused
    /// text field/area routes it through the field editor's `cancelOperation`; claiming it in
    /// `performKeyEquivalent` catches both.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ModalEscape.handle(
            event, in: window, dismissing: dismiss.isDismissing, close: { self.onCancel() }
        ) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        CardChrome.reapplyTheme(to: card)
        header.textColor = chrome.foreground.nsColor
        envText.textColor = chrome.muted.nsColor
        envNote.textColor = chrome.ink(alpha: 0.4)
        let controls: [ThemeReapplying] = [titleField, whatHappened, exportButton, cancelButton, openButton]
        controls.forEach { $0.reapplyTheme() }
        titleGroup?.reapplyTheme()
        whatGroup?.reapplyTheme()
        envCaption.reapplyTheme()
    }

    // MARK: content

    private func buildContent() -> NSStackView {
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = Theme.current.chrome.foreground.nsColor
        header.stringValue = "Report an Issue"

        wireField(titleField)
        titleField.onEnter = { [weak self] in self?.moveVertical(1) }
        let titleGroup = LabeledField(caption: FieldCaption("TITLE", required: true), control: titleField)
        self.titleGroup = titleGroup

        whatHappened.onChange = { [weak self] in self?.refreshValidity() }
        whatHappened.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        whatHappened.onArrowDown = { [weak self] in self?.moveVertical(1) }
        whatHappened.onTab = { [weak self] in self?.focus(self?.exportButton) }
        whatHappened.onBacktab = { [weak self] in self?.moveTab(-1) }
        whatHappened.onSubmit = { [weak self] in self?.submit() }
        let whatGroup = LabeledField(
            caption: FieldCaption("WHAT HAPPENED", required: true), control: whatHappened)
        self.whatGroup = whatGroup

        envText.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        envText.textColor = Theme.current.chrome.muted.nsColor
        envText.isSelectable = true
        envText.stringValue = report.plainText
        envNote.font = .systemFont(ofSize: 11)
        envNote.textColor = Theme.current.chrome.ink(alpha: 0.4)
        let envGroup = Self.vStack([envCaption, envText, envNote], spacing: 5)

        let footer = buildFooter()

        let content = NSStackView(views: [header, titleGroup, whatGroup, envGroup, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        }
        return content
    }

    private func buildFooter() -> NSStackView {
        exportButton.onTap = { [weak self] in self?.onExportDiagnostics() }
        cancelButton.onTap = { [weak self] in self?.onCancel() }
        openButton.onTap = { [weak self] in self?.submit() }

        for button in [exportButton, cancelButton, openButton] {
            button.isKeyboardFocusable = true
            button.onArrowUp = { [weak self] in self?.moveVertical(-1) }
            button.onArrowDown = { [weak self] in self?.moveVertical(1) }
        }
        // The footer reads left to right as Export · Cancel · Open, walked with Left/Right; Open is
        // the footer's single vertical stop (its default focus), Cancel and Export hang off it.
        exportButton.onArrowRight = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onArrowLeft = { [weak self] in self?.focus(self?.exportButton) }
        cancelButton.onArrowRight = { [weak self] in self?.focus(self?.openButton) }
        openButton.onArrowLeft = { [weak self] in self?.focus(self?.cancelButton) }
        // Tab walks every button in reading order, then wraps to the top; Shift-Tab reverses.
        exportButton.onTab = { [weak self] in self?.focus(self?.cancelButton) }
        exportButton.onBacktab = { [weak self] in self?.focus(self?.whatHappened.textView) }
        cancelButton.onTab = { [weak self] in self?.focus(self?.openButton) }
        cancelButton.onBacktab = { [weak self] in self?.focus(self?.exportButton) }
        openButton.onTab = { [weak self] in self?.moveTab(1) }
        openButton.onBacktab = { [weak self] in self?.focus(self?.cancelButton) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return Self.hStack([spacer, exportButton, cancelButton, openButton], spacing: 8)
    }

    // MARK: keyboard focus ring

    /// Up/Down order, top to bottom. The footer is one vertical stop anchored on Open; Cancel and
    /// Export are reached from it with Left/Right, not Up/Down.
    private func verticalStops() -> [NSView] {
        [titleField.field, whatHappened.textView, openButton]
    }

    private func moveVertical(_ delta: Int) {
        let stops = verticalStops()
        let anchor = currentVerticalAnchor(in: stops).flatMap { anchor in stops.firstIndex { $0 === anchor } }
        guard let next = KeyboardFocus.step(from: anchor, delta: delta, count: stops.count) else { return }
        window?.makeFirstResponder(stops[next])
    }

    private func moveTab(_ delta: Int) {
        let stops = verticalStops()
        let anchor = currentVerticalAnchor(in: stops).flatMap { anchor in stops.firstIndex { $0 === anchor } }
        guard let next = KeyboardFocus.step(from: anchor, delta: delta, count: stops.count, wrap: true)
        else { return }
        window?.makeFirstResponder(stops[next])
    }

    /// The vertical stop representing the current focus — the focused stop itself, or Open when the
    /// focus is on Cancel or Export (the footer's Left/Right pair).
    private func currentVerticalAnchor(in stops: [NSView]) -> NSView? {
        if let direct = stops.first(where: isFocused) { return direct }
        if isFocused(cancelButton) || isFocused(exportButton) { return openButton }
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

    private func focus(_ view: NSView?) {
        guard let view else { return }
        window?.makeFirstResponder(view)
    }

    // MARK: submit + validation

    private func submit() {
        if let firstInvalid = validate(includeRequired: true) {
            window?.makeFirstResponder(firstInvalid)
            return
        }
        let issue = IssueReport(
            title: titleField.text.trimmingCharacters(in: .whitespacesAndNewlines),
            whatHappened: whatHappened.text.trimmingCharacters(in: .whitespacesAndNewlines),
            report: report)
        onOpenURL(issue.url)
    }

    /// Set each field's inline message and return the first offending field to focus (nil when
    /// submittable). `includeRequired` gates the mandatory-but-empty checks: false on the live pass
    /// (don't flag an untouched field), true on a submit attempt.
    @discardableResult
    private func validate(includeRequired: Bool) -> NSView? {
        var firstInvalid: NSView?
        let title = titleField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let what = whatHappened.text.trimmingCharacters(in: .whitespacesAndNewlines)

        let titleMessage = (includeRequired && title.isEmpty) ? "Add a title." : nil
        titleGroup?.setMessage(titleMessage)
        if titleMessage != nil { firstInvalid = titleField.field }

        let whatMessage = (includeRequired && what.isEmpty) ? "Describe what happened." : nil
        whatGroup?.setMessage(whatMessage)
        if whatMessage != nil, firstInvalid == nil { firstInvalid = whatHappened.textView }

        return firstInvalid
    }

    private func refreshValidity() { validate(includeRequired: false) }

    // MARK: layout helpers

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
