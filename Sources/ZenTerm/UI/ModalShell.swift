import AppKit

// Full-bleed so its backdrop swallows clicks on whatever is underneath.
class ModalShell: NSView, ThemeReapplying {
    static let submitChord = Chord(command: true, key: "⏎")

    let card = CardView()
    private let onCancel: () -> Void
    private let onDismiss: (() -> Void)?
    private var gate = DismissGate()
    private(set) lazy var confirm = ConfirmSlot(over: self)

    var isDismissing: Bool { gate.isDismissing }
    // Declared on the class: a protocol-extension default would bind statically in `performKeyEquivalent`.
    var isShowingOverlaidCard: Bool { confirm.isShowing }
    var isBusy: Bool { false }
    var hasUnsavedChanges: Bool { false }

    init(width: CGFloat, onCancel: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        self.onCancel = onCancel
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let backdrop = BackdropView(onClick: { [weak self] in self?.dismiss() })
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        CardChrome.apply(to: card)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let cardWidth = card.widthAnchor.constraint(equalToConstant: width)
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
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func submitButton(title: String) -> AppButton {
        AppButton(
            title: title, variant: .primary, shortcut: submitChord.displayGlyph,
            keyEquivalent: "\r", keyEquivalentModifierMask: .command)
    }

    func embed(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }

    func focus(_ view: NSView?) {
        guard let view else { return }
        window?.makeFirstResponder(view)
    }

    func cancel() { leave(through: onCancel) }

    func dismiss() { leave(through: onDismiss ?? onCancel) }

    // The Cancel button is an explicit choice, so it never asks about unsaved changes.
    func cancelDiscardingChanges() {
        guard !isDismissing, !isBusy else { return }
        onCancel()
    }

    private func leave(through exit: @escaping () -> Void) {
        guard !isDismissing, !isBusy, !confirm.isShowing else { return }
        guard hasUnsavedChanges else { return exit() }
        let returnFocus = focusedView
        confirm.present(
            ConfirmCard(
                title: "Unsaved changes", message: "Closing now discards your changes.",
                cancelLabel: "Keep editing", confirmLabel: "Discard changes",
                onCancel: { [weak self, weak returnFocus] in
                    self?.confirm.dismiss { self?.focus(returnFocus) }
                },
                onConfirm: { [weak self] in self?.confirm.dismiss(then: exit) }))
    }

    private var focusedView: NSView? {
        let responder = window?.firstResponder
        if let editor = responder as? NSTextView, let field = editor.delegate as? NSTextField { return field }
        return responder as? NSView
    }

    func animateIn() {
        superview?.layoutSubtreeIfNeeded()
        Motion.springScaleFade(card, appearing: true)
    }

    func animateOut(completion: @escaping () -> Void) {
        guard gate.begin() else { return }
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }

    func reapplyTheme() {
        CardChrome.reapplyTheme(to: card)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isDismissing ? nil : super.hitTest(point)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !isShowingOverlaidCard,
            ModalEscape.handle(event, in: window, dismissing: isDismissing, close: { self.cancel() })
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
