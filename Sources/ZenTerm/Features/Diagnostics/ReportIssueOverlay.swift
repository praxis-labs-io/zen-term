import AppKit

final class ReportIssueOverlay: ModalShell, ModalOverlay {
    static let width: CGFloat = 460

    private struct Inputs: Equatable {
        let title, whatHappened: String
    }

    private let report: SystemReport
    private let onOpenURL: (URL) -> String?
    private let onExportDiagnostics: () -> Void

    private let header = ModalHeader(title: "Report an Issue")
    private let titleField = FieldBox(placeholder: "A short summary")
    private let whatHappened = TextAreaBox(placeholder: "What went wrong, and what you expected instead")
    private var titleGroup: LabeledField?
    private var whatGroup: LabeledField?
    private let envCaption = SectionCaption("Environment")
    private let envText = NSTextField(wrappingLabelWithString: "")
    private let envNote = NSTextField(labelWithString: "Sent with your report")

    private let exportButton = AppButton(title: "Export Diagnostics…", variant: .secondary)
    private let cancelButton = AppButton(title: "Cancel", variant: .secondary)
    private let openButton = ModalShell.submitButton(title: "Open on GitHub")
    private let errorLabel = FormErrorLabel(maximumLines: 3)
    private var openingInputs: Inputs?

    init(
        report: SystemReport,
        onOpenURL: @escaping (URL) -> String?, onExportDiagnostics: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.report = report
        self.onOpenURL = onOpenURL
        self.onExportDiagnostics = onExportDiagnostics
        super.init(width: Self.width, onCancel: onCancel)
        embed(buildContent())
        openingInputs = inputs
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func owns(_ chord: Chord) -> Bool { chord == Self.submitChord }

    override var hasUnsavedChanges: Bool { inputs != openingInputs }

    private var inputs: Inputs { Inputs(title: titleField.text, whatHappened: whatHappened.text) }

    func focusInitialResponder() { window?.makeFirstResponder(titleField.field) }

    override func reapplyTheme() {
        super.reapplyTheme()
        let chrome = Theme.current.chrome
        envText.textColor = chrome.ink(.muted)
        envText.applyThemedEditor()
        envNote.textColor = chrome.ink(.muted)
    }

    private func buildContent() -> NSStackView {
        wireField(titleField)
        titleField.onEnter = { [weak self] in self?.moveVertical(1) }
        let titleGroup = LabeledField(caption: SectionCaption("Title", required: true), control: titleField)
        self.titleGroup = titleGroup

        whatHappened.onChange = { [weak self] in self?.refreshValidity() }
        whatHappened.onArrowUp = { [weak self] in self?.moveVertical(-1) }
        whatHappened.onArrowDown = { [weak self] in self?.moveVertical(1) }
        whatHappened.onTab = { [weak self] in self?.focus(self?.exportButton) }
        whatHappened.onBacktab = { [weak self] in self?.moveTab(-1) }
        whatHappened.onSubmit = { [weak self] in self?.submit() }
        let whatGroup = LabeledField(
            caption: SectionCaption("What happened", required: true), control: whatHappened)
        self.whatGroup = whatGroup

        envText.font = ChromeType.font(.caption, face: .mono)
        envText.textColor = Theme.current.chrome.ink(.muted)
        envText.isSelectable = true
        envText.stringValue = report.plainText
        envNote.font = ChromeType.font(.caption)
        envNote.textColor = Theme.current.chrome.ink(.muted)
        let envGroup = Self.vStack([envCaption, envText, envNote], spacing: ChromeMetrics.Spacing.s6)

        let footer = buildFooter()

        let content = NSStackView(views: [header, titleGroup, whatGroup, envGroup, errorLabel, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = ChromeMetrics.Spacing.modalSectionGap
        content.edgeInsets = ChromeMetrics.Spacing.modalInsets
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(
                equalTo: content.widthAnchor,
                constant: -(ChromeMetrics.Spacing.modalInsets.left + ChromeMetrics.Spacing.modalInsets.right)
            ).isActive = true
        }
        return content
    }

    private func buildFooter() -> ModalActionBar {
        exportButton.onTap = { [weak self] in
            guard let self, !self.isDismissing else { return }
            self.onExportDiagnostics()
        }
        cancelButton.onTap = { [weak self] in self?.cancelDiscardingChanges() }
        openButton.onTap = { [weak self] in self?.submit() }

        for button in [exportButton, cancelButton, openButton] {
            button.isKeyboardFocusable = true
            button.onArrowUp = { [weak self] in self?.moveVertical(-1) }
            button.onArrowDown = { [weak self] in self?.moveVertical(1) }
        }
        exportButton.onArrowRight = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onArrowLeft = { [weak self] in self?.focus(self?.exportButton) }
        cancelButton.onArrowRight = { [weak self] in self?.focus(self?.openButton) }
        openButton.onArrowLeft = { [weak self] in self?.focus(self?.cancelButton) }
        exportButton.onTab = { [weak self] in self?.focus(self?.cancelButton) }
        exportButton.onBacktab = { [weak self] in self?.focus(self?.whatHappened.textView) }
        cancelButton.onTab = { [weak self] in self?.focus(self?.openButton) }
        cancelButton.onBacktab = { [weak self] in self?.focus(self?.exportButton) }
        openButton.onTab = { [weak self] in self?.moveTab(1) }
        openButton.onBacktab = { [weak self] in self?.focus(self?.cancelButton) }

        return ModalActionBar(trailing: [exportButton, cancelButton, openButton])
    }

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

    private func submit() {
        guard !isDismissing, !confirm.isShowing else { return }
        errorLabel.clear()
        let validation = validate(submitting: true)
        guard validation.isValid else { return validation.revealFirstInvalid() }
        let issue = IssueReport(
            title: titleField.text.trimmingCharacters(in: .whitespacesAndNewlines),
            whatHappened: whatHappened.text.trimmingCharacters(in: .whitespacesAndNewlines),
            report: report)
        if let failure = onOpenURL(issue.url) {
            errorLabel.show(failure)
            focus(openButton)
        }
    }

    @discardableResult
    private func validate(submitting: Bool) -> FormValidation {
        var validation = FormValidation()
        let title = titleField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let what = whatHappened.text.trimmingCharacters(in: .whitespacesAndNewlines)
        validation.flag(
            titleGroup, submitting && title.isEmpty ? "Add a title." : nil, at: titleField.field)
        validation.flag(
            whatGroup, submitting && what.isEmpty ? "Describe what happened." : nil, at: whatHappened.textView)
        return validation
    }

    private func refreshValidity() {
        errorLabel.clear()
        validate(submitting: false)
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
