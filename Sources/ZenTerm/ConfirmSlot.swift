import AppKit

@MainActor
final class ConfirmSlot {
    private unowned let host: NSView
    private(set) var card: ConfirmCard?
    private var leaving: ConfirmCard?

    var isShowing: Bool { card != nil || leaving != nil }

    init(over host: NSView) {
        self.host = host
    }

    func present(_ card: ConfirmCard) {
        self.card?.removeFromSuperview()
        leaving?.removeFromSuperview()
        leaving = nil
        card.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            card.topAnchor.constraint(equalTo: host.topAnchor),
            card.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        self.card = card
        card.focusInitialResponder()
        card.animateIn()
    }

    // Keeps the slot showing until the exit completes: releasing it early hands Esc back to the host, which closes the host.
    func dismiss(then: @escaping () -> Void) {
        guard let card else { return }
        self.card = nil
        leaving = card
        card.animateOut { [weak self, weak card] in
            card?.removeFromSuperview()
            guard let self, self.leaving === card else { return }
            self.leaving = nil
        }
        then()
    }
}
