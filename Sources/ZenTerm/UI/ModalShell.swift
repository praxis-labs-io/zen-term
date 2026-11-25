import AppKit

// Full-bleed so its backdrop swallows clicks on whatever is underneath.
class ModalShell: NSView, ThemeReapplying {
    static let submitChord = Chord(command: true, key: "⏎")

    enum Placement {
        case centered
        // A list that filters as you type grows and shrinks from the bottom, so its search field stays put.
        case pinnedTop
    }

    private static let pinnedTopInset = ChromeMetrics.Spacing.s32

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

    init(
        width: CGFloat, placement: Placement = .centered, onCancel: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
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
            cardWidth,
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.92),
        ])
        switch placement {
        case .centered:
            NSLayoutConstraint.activate([
                card.centerYAnchor.constraint(equalTo: centerYAnchor),
                card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.92),
            ])
        case .pinnedTop:
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: topAnchor, constant: Self.pinnedTopInset),
                card.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.pinnedTopInset),
            ])
        }
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
        let selection = (window?.firstResponder as? NSTextView)?.selectedRange()
        confirm.present(
            ConfirmCard(
                .unsavedChanges,
                onCancel: { [weak self, weak returnFocus] in
                    self?.confirm.dismiss { self?.refocus(returnFocus, selecting: selection) }
                },
                onConfirm: { [weak self] in self?.confirm.dismiss(then: exit) }))
    }

    private func refocus(_ view: NSView?, selecting selection: NSRange?) {
        guard let view, view.window === window, !view.isHiddenOrHasHiddenAncestor else {
            (self as? ModalOverlay)?.focusInitialResponder()
            return
        }
        focus(view)
        guard let selection, let editor = window?.firstResponder as? NSTextView else { return }
        editor.setSelectedRange(selection)
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
