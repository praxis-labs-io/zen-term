import AppKit

final class AddSSHHostOverlay: NSView, ModalOverlay {
    enum Mode {
        case add(taken: Set<String>)
        case edit(SSHHostEntry, address: String?)
    }

    struct Removal {
        let consequence: () -> String?
        let perform: () -> String?
    }

    private let mode: Mode
    private let removal: Removal?
    private let onSubmit: (SSHHostEntry) -> String?
    private let onCancel: () -> Void

    private let card = CardView()
    private var dismiss = DismissGate()
    private lazy var confirm = ConfirmSlot(over: self)

    private let header = NSTextField(labelWithString: "")
    private let hostField = FieldBox(placeholder: "user@host or alias")
    private lazy var hostCaption = FieldCaption("Host", required: editing == nil)
    private lazy var hostGroup = LabeledField(caption: hostCaption, control: hostField)
    private let nameField = FieldBox(placeholder: "Shown in place of the host")
    private let nameCaption = FieldCaption("Name", required: false)
    private lazy var nameGroup = LabeledField(caption: nameCaption, control: nameField)
    private let errorLabel = FormErrorLabel()
    private let cancelButton = AppButton(title: "Cancel", variant: .secondary)
    private let submitButton = AppButton(title: "", variant: .primary, keyEquivalent: "\r")
    private let removeButton = AppButton(title: "Remove", variant: .destructive)

    private var editing: (entry: SSHHostEntry, address: String?)? {
        guard case .edit(let entry, let address) = mode else { return nil }
        return (entry, address)
    }

    init(
        mode: Mode, background: NSColor, removal: Removal? = nil, onSubmit: @escaping (SSHHostEntry) -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.removal = removal
        self.onSubmit = onSubmit
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

        let cardWidth = card.widthAnchor.constraint(equalToConstant: 380)
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

            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func problem(with host: String) -> String? {
        if host.isEmpty { return "Enter a host." }
        if host.contains(where: { $0.isWhitespace || ",#\"".contains($0) }) {
            return "Can't contain spaces, commas, # or \"."
        }
        if host.hasPrefix("-") { return "Can't start with -." }
        if host.hasSuffix(":") { return "Can't end with :." }
        return nil
    }

    static func problem(withName name: String) -> String? {
        name.contains("\"") ? "Can't contain \"." : nil
    }

    var isShowingOverlaidCard: Bool { confirm.isShowing }

    func focusInitialResponder() {
        if let card = confirm.card { return card.focusInitialResponder() }
        let field = editing == nil ? hostField.field : nameField.field
        window?.makeFirstResponder(field)
        field.applyThemedCaret()
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
            event, in: window, dismissing: dismiss.isDismissing, close: { self.onCancel() })
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func reapplyTheme() {
        CardChrome.reapplyTheme(to: card)
        header.textColor = Theme.current.chrome.foreground.nsColor
        errorLabel.reapplyTheme()
        confirm.card?.reapplyTheme()
        hostGroup.reapplyTheme()
        nameGroup.reapplyTheme()
        let controls: [ThemeReapplying] = [hostField, nameField, cancelButton, submitButton, removeButton]
        controls.forEach { $0.reapplyTheme() }
        if let editing { showFixedHost(editing.entry.alias, address: editing.address) }
    }

    private func buildContent() -> NSStackView {
        header.stringValue = editing == nil ? "Add SSH Host" : "Edit SSH Host"
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = Theme.current.chrome.foreground.nsColor
        submitButton.setTitle(editing == nil ? "Add" : "Save")

        hostField.onEnter = { [weak self] in self?.focus(self?.nameField.field) }
        hostField.onArrowDown = { [weak self] in self?.focus(self?.nameField.field) }
        hostField.onSubmit = { [weak self] in self?.submit() }
        hostField.onChange = { [weak self] in
            self?.hostGroup.setMessage(nil)
            self?.errorLabel.clear()
        }
        hostField.onTab = { [weak self] in self?.focus(self?.nameField.field) }
        hostField.onBacktab = { [weak self] in self?.focus(self?.submitButton) }

        nameField.onEnter = { [weak self] in self?.submit() }
        nameField.onSubmit = { [weak self] in self?.submit() }
        nameField.onChange = { [weak self] in
            self?.nameGroup.setMessage(nil)
            self?.errorLabel.clear()
        }
        nameField.onTab = { [weak self] in self?.focus(self?.cancelButton) }

        cancelButton.onTap = { [weak self] in self?.onCancel() }
        submitButton.onTap = { [weak self] in self?.submit() }
        for button in [cancelButton, submitButton] {
            button.isKeyboardFocusable = true
        }
        cancelButton.onArrowRight = { [weak self] in self?.focus(self?.submitButton) }
        submitButton.onArrowLeft = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onTab = { [weak self] in self?.focus(self?.submitButton) }
        submitButton.onBacktab = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onBacktab = { [weak self] in self?.focus(self?.nameField.field) }

        if let editing {
            hostField.field.isEditable = false
            hostField.field.isSelectable = false
            showFixedHost(editing.entry.alias, address: editing.address)
            nameField.setText(editing.entry.name ?? "")
            nameField.onBacktab = { [weak self] in self?.focus(self?.submitButton) }
            submitButton.onTab = { [weak self] in self?.focus(self?.nameField.field) }
            if removal != nil { wireRemove() }
        } else {
            nameField.onArrowUp = { [weak self] in self?.focus(self?.hostField.field) }
            nameField.onBacktab = { [weak self] in self?.focus(self?.hostField.field) }
            submitButton.onTab = { [weak self] in self?.focus(self?.hostField.field) }
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let trailing = [spacer, cancelButton, submitButton]
        let footerViews = removal == nil ? trailing : [removeButton] + trailing
        let footer = NSStackView(views: footerViews)
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [header, hostGroup, nameGroup, errorLabel, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        }
        return content
    }

    private func wireRemove() {
        removeButton.isKeyboardFocusable = true
        removeButton.onTap = { [weak self] in self?.remove() }
        removeButton.onArrowUp = { [weak self] in self?.focus(self?.nameField.field) }
        removeButton.onArrowRight = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onArrowLeft = { [weak self] in self?.focus(self?.removeButton) }
        removeButton.onTab = { [weak self] in self?.focus(self?.nameField.field) }
        removeButton.onBacktab = { [weak self] in self?.focus(self?.submitButton) }
        submitButton.onTab = { [weak self] in self?.focus(self?.removeButton) }
        nameField.onBacktab = { [weak self] in self?.focus(self?.removeButton) }
    }

    private func remove() {
        guard let removal, let editing, !confirm.isShowing else { return }
        errorLabel.clear()
        guard let consequence = removal.consequence() else { return performRemoval() }
        let name = editing.entry.displayName
        confirm.present(
            ConfirmCard(
                title: "Remove \(name)", message: "Removing \(name) will \(consequence).",
                confirmLabel: "Remove", background: Theme.current.chrome.background.nsColor,
                onCancel: { [weak self] in self?.confirm.dismiss { self?.focus(self?.removeButton) } },
                onConfirm: { [weak self] in self?.confirm.dismiss { self?.performRemoval() } }))
    }

    private func performRemoval() {
        guard let failure = removal?.perform() else { return }
        errorLabel.show(failure)
        focus(removeButton)
    }

    private func focus(_ view: NSView?) {
        guard let view else { return }
        window?.makeFirstResponder(view)
    }

    private func showFixedHost(_ alias: String, address: String?) {
        let chrome = Theme.current.chrome
        let line = NSMutableParagraphStyle()
        line.lineBreakMode = .byTruncatingTail
        let font = hostField.field.font ?? .systemFont(ofSize: 13)
        let text = NSMutableAttributedString(
            string: alias,
            attributes: [.font: font, .foregroundColor: chrome.foreground.nsColor, .paragraphStyle: line])
        if let address {
            text.append(
                NSAttributedString(
                    string: "  \(address)",
                    attributes: [.font: font, .foregroundColor: chrome.ink(.muted), .paragraphStyle: line]))
        }
        hostField.field.maximumNumberOfLines = 1
        hostField.field.attributedStringValue = text
    }

    private func submit() {
        guard let host = submittedHost() else { return }
        let name = nameField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.problem(withName: name) {
            nameGroup.setMessage(problem)
            focus(nameField.field)
            return
        }
        if let failure = onSubmit(SSHHostEntry(alias: host, name: name.isEmpty ? nil : name)) {
            errorLabel.show(failure)
            focusInitialResponder()
        }
    }

    private func submittedHost() -> String? {
        let taken: Set<String>
        switch mode {
        case .edit(let entry, _): return entry.alias
        case .add(let aliases): taken = aliases
        }
        let host = hostField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let problem = Self.problem(with: host) ?? (taken.contains(host) ? "Already added." : nil) else {
            return host
        }
        hostGroup.setMessage(problem)
        focus(hostField.field)
        return nil
    }
}
