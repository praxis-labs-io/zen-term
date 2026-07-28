import AppKit

/// The bare card ⌘+ / ⌘- / ⌘0 raise, showing the size the terminal is now at ("16pt") and nothing
/// else (ZEN-224). No icon badge, no description, no buttons: it answers one question — where the
/// user currently stands — and a stepped size is only legible if the answer is the whole card.
///
/// A card rather than a `ToastView` variant. `ToastView` builds its badge, message label, variant
/// border, actions row and focus gating structurally, so a "minimal" mode there would be a second
/// layout living inside a shared type every other notice depends on. `ToastPresenter` already hosts
/// caller-built cards in the same stack (`present(card:)`), which is the path the update card takes.
///
/// **It updates in place.** Held chords auto-repeat, so a card per keystroke would stack a column of
/// stale numbers; the throttle the zoom-block notice uses would do the opposite and freeze the first
/// number while the panes kept growing. Neither reports where the user stands, which is the only
/// thing this card is for — so a repeat re-labels the card already up and restarts its timer.
final class FontSizeCard: ShadowCardView {
    private let label: NSTextField

    /// Tabular figures: the size changes under a card that stays put, and proportional digits would
    /// shift the text sideways on every step (1 is narrower than 8).
    private static let font: NSFont = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = FloatShadow.edge.cgColor
        FloatShadow.applyShadow(to: self)

        label.font = Self.font
        label.textColor = Theme.current.chrome.foreground.nsColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Re-label the card already on screen, for a repeat of the chord that raised it.
    func update(text: String) { label.stringValue = text }

    /// Recolor after a live theme change, matching every other card that can outlive one.
    func reapplyTheme() {
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderColor = FloatShadow.edge.cgColor
        label.textColor = Theme.current.chrome.foreground.nsColor
    }
}
