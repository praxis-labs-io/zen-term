import AppKit

final class RenameTabOverlay: NSView, ModalOverlay {
    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void

    private let card = CardView()
    private var dismiss = DismissGate()

    private let header = NSTextField(labelWithString: "")
    private let nameField: FieldBox
    private let cancelButton = AppButton(title: "Cancel", variant: .secondary)
    private let renameButton = AppButton(title: "Rename", variant: .primary, keyEquivalent: "\r")

    init(
        current: String, liveTitle: String, background: NSColor,
        onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        nameField = FieldBox(placeholder: liveTitle)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let backdrop = BackdropView(onClick: onCancel)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        CardChrome.apply(to: card, background: background)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        nameField.setText(current)
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

    var nameFieldForTesting: FieldBox { nameField }
    var renameButtonForTesting: AppButton { renameButton }

    func focusInitialResponder() {
        window?.makeFirstResponder(nameField.field)
        nameField.field.applyThemedCaret()
        nameField.field.currentEditor()?.selectAll(nil)
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
        let chrome = Theme.current.chrome
        CardChrome.reapplyTheme(to: card)
        header.textColor = chrome.foreground.nsColor
        let controls: [ThemeReapplying] = [nameField, cancelButton, renameButton]
        controls.forEach { $0.reapplyTheme() }
    }

    private func buildContent() -> NSStackView {
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = Theme.current.chrome.foreground.nsColor
        header.stringValue = "Rename Tab"

        nameField.onEnter = { [weak self] in self?.submit() }
        nameField.onSubmit = { [weak self] in self?.submit() }

        cancelButton.onTap = { [weak self] in self?.onCancel() }
        renameButton.onTap = { [weak self] in self?.submit() }
        for button in [cancelButton, renameButton] {
            button.isKeyboardFocusable = true
        }
        cancelButton.onArrowRight = { [weak self] in self?.focus(self?.renameButton) }
        renameButton.onArrowLeft = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onTab = { [weak self] in self?.focus(self?.renameButton) }
        renameButton.onTab = { [weak self] in self?.focus(self?.nameField.field) }
        renameButton.onBacktab = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onBacktab = { [weak self] in self?.focus(self?.nameField.field) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, cancelButton, renameButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [header, nameField, footer])
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
        onSubmit(nameField.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
