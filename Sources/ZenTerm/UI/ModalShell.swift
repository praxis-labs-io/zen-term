import AppKit

// Full-bleed so its backdrop swallows clicks on whatever is underneath.
class ModalShell: NSView, ThemeReapplying {
    static let submitChord = Chord(command: true, key: "⏎")

    let card = CardView()
    private let onCancel: () -> Void
    private let onDismiss: (() -> Void)?
    private var gate = DismissGate()

    var isDismissing: Bool { gate.isDismissing }
    // Declared on the class: a protocol-extension default would bind statically in `performKeyEquivalent`.
    var isShowingOverlaidCard: Bool { false }
    var isBusy: Bool { false }

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

    func cancel() {
        guard !isDismissing, !isBusy else { return }
        onCancel()
    }

    func dismiss() {
        guard !isDismissing, !isBusy else { return }
        (onDismiss ?? onCancel)()
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
