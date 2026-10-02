import AppKit

final class AddSSHHostOverlay: NSView, ModalOverlay {
    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void

    private let card = CardView()
    private var dismiss = DismissGate()

    private let header = NSTextField(labelWithString: "Add SSH Host")
    private let hostField = FieldBox(placeholder: "user@host or alias")
    private let hostCaption = FieldCaption("Host", required: true)
    private lazy var hostGroup = LabeledField(caption: hostCaption, control: hostField)
    private let cancelButton = AppButton(title: "Cancel", variant: .secondary)
    private let addButton = AppButton(title: "Add", variant: .primary, keyEquivalent: "\r")

    init(background: NSColor, onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
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
        return nil
    }

    func focusInitialResponder() {
        window?.makeFirstResponder(hostField.field)
        hostField.field.applyThemedCaret()
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
        hostGroup.reapplyTheme()
        let controls: [ThemeReapplying] = [hostField, cancelButton, addButton]
        controls.forEach { $0.reapplyTheme() }
    }

    private func buildContent() -> NSStackView {
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = Theme.current.chrome.foreground.nsColor

        hostField.onEnter = { [weak self] in self?.submit() }
        hostField.onSubmit = { [weak self] in self?.submit() }
        hostField.onChange = { [weak self] in self?.hostGroup.setMessage(nil) }

        cancelButton.onTap = { [weak self] in self?.onCancel() }
        addButton.onTap = { [weak self] in self?.submit() }
        for button in [cancelButton, addButton] {
            button.isKeyboardFocusable = true
        }
        cancelButton.onArrowRight = { [weak self] in self?.focus(self?.addButton) }
        addButton.onArrowLeft = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onTab = { [weak self] in self?.focus(self?.addButton) }
        addButton.onTab = { [weak self] in self?.focus(self?.hostField.field) }
        addButton.onBacktab = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onBacktab = { [weak self] in self?.focus(self?.hostField.field) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, cancelButton, addButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [header, hostGroup, footer])
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

    private func focus(_ view: NSView?) {
        guard let view else { return }
        window?.makeFirstResponder(view)
    }

    private func submit() {
        let host = hostField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.problem(with: host) {
            hostGroup.setMessage(problem)
            return
        }
        onSubmit(host)
    }
}
