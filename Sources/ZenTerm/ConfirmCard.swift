import AppKit

/// A confirmation shown over a card that stays put, for a consequence that outlives the window:
/// removing a worktree deletes a folder and cannot be taken back. Closing a pane or a window is a
/// smaller thing and keeps the toast confirm.
///
/// Full-bleed, so its backdrop swallows clicks on the list underneath. `ConfirmCard` owns Esc and
/// its buttons own Return; the host stops claiming both while one is up.
final class ConfirmCard: NSView {
    private let onCancel: () -> Void
    private let onConfirm: () -> Void

    private let card = CardView()
    private var dismiss = DismissGate()
    private let header = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let cancelButton = AppButton(title: "Cancel", variant: .secondary)
    private let confirmButton: AppButton

    init(
        title: String, message: String, confirmLabel: String, background: NSColor,
        onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void
    ) {
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        confirmButton = AppButton(title: confirmLabel, variant: .destructive)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // Clicking out of a confirm answers it: no, the same as Esc.
        let backdrop = BackdropView(onClick: { [weak self] in self?.cancel() })
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        CardChrome.apply(to: card, background: background)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let content = buildContent(title: title, message: message)
        card.addSubview(content)

        let cardWidth = card.widthAnchor.constraint(equalToConstant: 420)
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

    /// The affirmative takes focus, so Return answers the question the card just asked. Esc and a
    /// click outside are the other way out, and both are one key or one click away.
    func focusInitialResponder() { window?.makeFirstResponder(confirmButton) }

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
            event, in: window, dismissing: dismiss.isDismissing, close: { self.cancel() })
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        CardChrome.reapplyTheme(to: card)
        header.textColor = chrome.foreground.nsColor
        messageLabel.textColor = chrome.ink(.muted)
        cancelButton.reapplyTheme()
        confirmButton.reapplyTheme()
    }

    private func cancel() {
        guard !dismiss.isDismissing else { return }
        onCancel()
    }

    private func buildContent(title: String, message: String) -> NSStackView {
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.textColor = Theme.current.chrome.foreground.nsColor
        header.stringValue = title

        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = Theme.current.chrome.ink(.muted)
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.stringValue = message

        cancelButton.onTap = { [weak self] in self?.cancel() }
        confirmButton.onTap = { [weak self] in
            guard let self, !self.dismiss.isDismissing else { return }
            self.onConfirm()
        }
        for button in [cancelButton, confirmButton] {
            button.isKeyboardFocusable = true
        }
        confirmButton.onArrowLeft = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onArrowRight = { [weak self] in self?.focus(self?.confirmButton) }
        confirmButton.onTab = { [weak self] in self?.focus(self?.cancelButton) }
        cancelButton.onTab = { [weak self] in self?.focus(self?.confirmButton) }
        cancelButton.onBacktab = { [weak self] in self?.focus(self?.confirmButton) }
        confirmButton.onBacktab = { [weak self] in self?.focus(self?.cancelButton) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, cancelButton, confirmButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let content = NSStackView(views: [header, messageLabel, footer])
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

    private func focus(_ view: NSView?) {
        guard let view else { return }
        window?.makeFirstResponder(view)
    }
}
