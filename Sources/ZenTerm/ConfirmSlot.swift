import AppKit

/// One `ConfirmCard` shown over an overlay that stays put underneath it: the row or the form being
/// asked about has to remain visible while the question is answered.
///
/// The slot is cleared in the exit animation's completion, not before it. The card is on screen for
/// that whole spring, and releasing it early hands Esc back to the host, which closes the host.
@MainActor
final class ConfirmSlot {
    private unowned let host: NSView
    private(set) var card: ConfirmCard?

    var isShowing: Bool { card != nil }

    init(over host: NSView) {
        self.host = host
    }

    func present(_ card: ConfirmCard) {
        self.card?.removeFromSuperview()
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

    /// Take the confirm down and run `then` so the host can take its keyboard back.
    func dismiss(then: @escaping () -> Void) {
        guard let card else { return }
        card.animateOut { [weak self, weak card] in
            card?.removeFromSuperview()
            guard let self, self.card === card else { return }
            self.card = nil
        }
        then()
    }
}
