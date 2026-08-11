import AppKit
import AppLog

/// The one auto-update card, a sibling of `ToastView` on the shared overlay-card
/// chrome (`FloatShadow` bg + neutral hairline + drop shadow) in the top-right toast stack. It
/// morphs in place across the update's states rather than stacking a card per state — the
/// `UpdateController` re-renders it as Sparkle drives the flow:
///
///   available    origami badge + "ZenTerm 0.2.0 is available" / "You're on 0.1.4"
///                + notes bullets + "What's new" + [Install] [Later] [Skip]
///   downloading  a theme-tinted progress bar
///   ready        "Ready to install" + [Relaunch] [Later]
///
/// Non-modal like a sticky toast: it never takes first responder, so it can't steal keys from the
/// terminal (its buttons are click-only, no Return/Esc equivalents). The top-right keycap slot names
/// the "Check for Updates" chord — empty until the user binds one, since that chord has no
/// default and an unbound glyph would lie; it lights up the moment a binding exists.
final class UpdateCardView: ShadowCardView {
    /// One update state to render. Pure data; the buttons' behavior comes from `Actions`, kept
    /// apart so a window-close re-home can rebuild the card from the same state and the still-valid
    /// Sparkle reply closures.
    enum State: Equatable {
        case available(version: String, current: String, notes: [String], notesURL: URL?)
        case downloading(fraction: Double?)  // nil until the expected length is known
        case ready(version: String)

        /// A short, non-sensitive label for the update diagnostic log. Only the version
        /// string, already public in the appcast, appears here — nothing user-specific.
        var logLabel: String {
            switch self {
            case .available(let version, _, _, _): return "available \(version)"
            case .downloading(let fraction):
                return "downloading \(fraction.map { "\(Int($0 * 100))%" } ?? "…")"
            case .ready(let version): return "ready \(version)"
            }
        }
    }

    /// The card's button callbacks. Only the ones a given state shows are read.
    struct Actions {
        var install: () -> Void = {}
        var later: () -> Void = {}
        var skip: () -> Void = {}
        var relaunch: () -> Void = {}
        var whatsNew: (URL) -> Void = { _ in }
    }

    /// Fixed card width — reads as a deliberate column beside the 300pt toasts, wide enough for a
    /// release-note line. Layout/placement is the runbook's; this is the one number the notes wrap
    /// column is derived from.
    static let width: CGFloat = 360
    private static let inset: CGFloat = 12
    private static let badgeSize: CGFloat = 28
    private static let rootSpacing: CGFloat = 12

    /// The notes column's wrap width (card width minus badge + gap + insets) and its font. Exposed
    /// so the bullets are *measured* against the real budget instead of eyeballed — the same reason
    /// `ToastView.messageMaxWidth` is. `UpdateCardTests` asserts this equals the derived inner width,
    /// so a change to the card/badge geometry can't silently leave the notes wrapping at a stale column.
    static let notesMaxWidth: CGFloat = width - inset * 2 - badgeSize - rootSpacing
    static let notesFont: NSFont = .systemFont(ofSize: 12)

    private var state: State
    private var actions: Actions

    private let badgeFill = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    /// The title row, retained so its trailing keycap can be rebuilt when the binding changes.
    private let header = NSStackView()
    /// The "Check for Updates" keycap in the header's trailing slot — nil while that action is
    /// unbound (its default), so an unbound glyph never lies. Resolved from the live keymap.
    private var checkKeycap: KeycapView?
    /// The content beneath the header (subtitle + notes / progress), rebuilt per state.
    private let bodyColumn = NSStackView()
    private let buttonRow = NSStackView()
    private let progressBar = UpdateProgressBar()

    init(state: State, actions: Actions) {
        self.state = state
        self.actions = actions
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        FloatShadow.applyShadow(to: self)

        // Accent-tinted origami badge (BrandMark → template image, tinted like an SF Symbol), matching
        // the toast badge idiom: an accent glyph on an accent-at-15% rounded square.
        badgeFill.wantsLayer = true
        badgeFill.layer?.cornerRadius = 7
        badgeFill.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = BrandMark.image("origami")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        badgeFill.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Title leading, keycap trailing — the slot names the "Check for Updates" chord, empty until
        // one is bound (like ToastView's shortcut slot). The spacer holds title and keycap apart.
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.init(rawValue: 1), for: .horizontal)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(headerSpacer)
        refreshKeycap()

        bodyColumn.orientation = .vertical
        bodyColumn.alignment = .leading
        bodyColumn.spacing = 6

        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 6

        let col = NSStackView(views: [header, bodyColumn, buttonRow])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 9
        header.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        bodyColumn.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        buttonRow.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        // Give the title row the badge's height so its centered title lines up with the badge's
        // center. Without this the row hugs the title's ~16pt and, top-aligned against the 28pt
        // badge, the title sits high instead of centered on the icon.
        header.heightAnchor.constraint(equalToConstant: Self.badgeSize).isActive = true

        let root = NSStackView(views: [badgeFill, col])
        root.orientation = .horizontal
        root.alignment = .top
        root.distribution = .fill
        root.spacing = Self.rootSpacing
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            badgeFill.widthAnchor.constraint(equalToConstant: Self.badgeSize),
            badgeFill.heightAnchor.constraint(equalToConstant: Self.badgeSize),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            iconView.centerXAnchor.constraint(equalTo: badgeFill.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: badgeFill.centerYAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            root.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
        ])

        applyColors()
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Morph the card to a new state in place (same card, rebuilt content). `actions` is refreshed
    /// too so a re-home keeps the live Sparkle reply closures. A downloading → downloading tick just
    /// advances the bar: download data arrives in hundreds of chunks, and rebuilding the whole body
    /// each time would churn Auto Layout on a hot path.
    func update(to newState: State, actions: Actions) {
        self.actions = actions
        if case .downloading = state, case .downloading(let fraction) = newState {
            state = newState
            progressBar.fraction = fraction
            return
        }
        state = newState
        render()
    }

    // MARK: - Rendering

    private func render() {
        titleLabel.stringValue = title(for: state)
        bodyColumn.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        switch state {
        case .available(_, let current, let notes, let notesURL):
            addBodyLabel(current, color: Theme.current.chrome.muted.nsColor)
            if !notes.isEmpty {
                addBodyLabel(
                    notes.map { "•  \($0)" }.joined(separator: "\n"),
                    color: Theme.current.chrome.foreground.nsColor)
            }
            if let notesURL {
                let link = AppButton(title: "What's new", variant: .secondary) { [weak self] in
                    self?.actions.whatsNew(notesURL)
                }
                bodyColumn.addArrangedSubview(link)
            }
            addButton("Install", variant: .primary) { [weak self] in self?.actions.install() }
            addButton("Later", variant: .secondary) { [weak self] in self?.actions.later() }
            addButton("Skip", variant: .secondary) { [weak self] in self?.actions.skip() }

        case .downloading(let fraction):
            progressBar.fraction = fraction
            bodyColumn.addArrangedSubview(progressBar)
            // Width tracks the column; the bar's own intrinsic height (4pt) sizes it vertically, so
            // no self-owned height constraint is re-added (and leaked) on each rebuild.
            progressBar.widthAnchor.constraint(equalTo: bodyColumn.widthAnchor).isActive = true

        case .ready(let version):
            addBodyLabel(
                "Relaunch to finish updating to \(version).",
                color: Theme.current.chrome.muted.nsColor)
            addButton("Relaunch", variant: .primary) { [weak self] in self?.actions.relaunch() }
            addButton("Later", variant: .secondary) { [weak self] in self?.actions.later() }
        }

        // A trailing spacer hugs the buttons to the leading edge.
        if !buttonRow.arrangedSubviews.isEmpty {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            buttonRow.addArrangedSubview(spacer)
        }

        needsLayout = true
    }

    private func title(for state: State) -> String {
        switch state {
        case .available(let version, _, _, _): return "ZenTerm \(version) is available"
        case .downloading: return "Downloading update"
        case .ready: return "Ready to install"
        }
    }

    private func addBodyLabel(_ text: String, color: NSColor) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Self.notesFont
        label.textColor = color
        label.preferredMaxLayoutWidth = Self.notesMaxWidth
        bodyColumn.addArrangedSubview(label)  // add before constraining — the width anchor needs a common ancestor
        label.widthAnchor.constraint(equalTo: bodyColumn.widthAnchor).isActive = true
    }

    private func addButton(_ title: String, variant: AppButton.Variant, onTap: @escaping () -> Void) {
        buttonRow.addArrangedSubview(
            AppButton(title: title, variant: variant) { [weak self] in
                // Log the tap before the action runs, so a reporter's bundle shows whether
                // repeated taps registered at the AppKit level at all (one line vs many).
                Log.info("update card tap: \(title) [\(self?.state.logLabel ?? "gone")]", category: .update)
                onTap()
            })
    }

    // MARK: - Theme

    private func applyColors() {
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderColor = FloatShadow.edge.cgColor
        // Theme-drive the title, or it falls back to NSColor.labelColor, which follows
        // effectiveAppearance (not Theme.current) and washes out to invisible on a light theme.
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        let accent = Theme.current.chrome.accent.nsColor
        badgeFill.layer?.backgroundColor = accent.withAlphaComponent(0.15).cgColor
        iconView.contentTintColor = accent
        progressBar.reapplyTheme()
    }

    /// Re-apply live chrome colors after a config change — the card can be up across a theme swap,
    /// so it recolors in place like `ToastView.reapplyTheme()`.
    func reapplyTheme() {
        applyColors()
        refreshKeycap()  // a chord bound/unbound while the card is up
        checkKeycap?.reapplyTheme()  // recolor when the glyph is unchanged (refreshKeycap was a no-op)
        render()  // labels/buttons re-read Theme.current as they rebuild
    }

    /// Rebuild the header keycap from the live "Check for Updates" binding. An empty glyph (the
    /// unbound default) leaves the slot empty; a bound one fills it. Mirrors `ToastView`'s
    /// `ShortcutSlot` — a no-op when the glyph is unchanged, so a plain re-render doesn't churn it.
    private func refreshKeycap() {
        let glyph = Chord.displayed(.checkForUpdates, in: GeneralConfig.current.keymap)?.displayGlyph ?? ""
        guard glyph != checkKeycap?.shortcut else { return }
        checkKeycap.map { header.removeArrangedSubview($0) }
        checkKeycap?.removeFromSuperview()
        checkKeycap = nil
        guard !glyph.isEmpty else { return }  // unbound → no keycap at all
        let cap = KeycapView(shortcut: glyph)
        header.addArrangedSubview(cap)
        checkKeycap = cap
    }

    // MARK: - Interaction

    /// Set when the card is being removed (a re-home or a dismiss). `ToastPresenter.remove` springs
    /// the card out via `Motion` directly, so there's no animateOut hook to arm this — the removal
    /// path (`WindowController.dismissUpdateCard`) calls `beginDismissal()` instead, and `hitTest`
    /// reads it so a click landing on the fading card can't fire a stale Sparkle reply.
    private var isDismissing = false

    func beginDismissal() { isDismissing = true }

    /// Non-modal: never first responder, so terminal input is never gated behind the card. A body
    /// click does nothing (the buttons answer); a card being removed ignores hits.
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { isDismissing ? nil : super.hitTest(point) }
}
