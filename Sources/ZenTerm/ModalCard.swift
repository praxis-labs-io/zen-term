import AppKit

/// A modal card overlay presented over a tab's tile region: a centered card with a
/// transparent click-catching backdrop, sprung in and out about its center. `WindowController`
/// stores exactly one at a time (`PaletteOverlay`'s pickers and `AddWorkspaceOverlay`) and drives
/// it through this protocol, so the present/close machinery is shared rather than duplicated per
/// overlay type.
protocol ModalOverlay: NSView {
    /// Make the overlay's primary input first responder — called by the host after presenting.
    func focusInitialResponder()
    /// Spring the card in (fade + subtle scale). Called after presenting.
    func animateIn()
    /// Spring the card back out, then run `completion` (the host removes the overlay).
    func animateOut(completion: @escaping () -> Void)
    /// Re-apply the overlay's theme-dependent colors after a live theme change. Default no-op;
    /// overlays with theme-dependent chrome override it.
    func reapplyTheme()
}

extension ModalOverlay {
    func reapplyTheme() {}
}

/// The card container: swallows clicks so a tap on the card's empty area doesn't fall through
/// to the backdrop (which would dismiss). Shared by every modal card.
final class CardView: ShadowCardView { override func mouseDown(with event: NSEvent) {} }

/// The shared modal-card chrome — rounded corners, a hairline `FloatShadow.edge` border, and the
/// float elevation shadow. Every modal card (palettes, settings, add-workspace, tool float) applied
/// exactly this by hand; `apply` sets it up and `reapplyTheme` re-derives the theme-dependent half
/// (fill + border) on a live theme swap.
enum CardChrome {
    static let cornerRadius: CGFloat = 12

    /// `halo: true` swaps the neutral hairline for the accent focus ring — the same signal a focused
    /// terminal pane wears. Reserved for the surfaces that steal focus from the pane behind them
    /// (the configured tool floats and the diff viewer), so the ring reads as "focus is here now";
    /// transient pickers and forms keep the neutral edge.
    ///
    static func apply(
        to card: NSView, background: NSColor, cornerRadius: CGFloat = CardChrome.cornerRadius,
        halo: Bool = false
    ) {
        applyEdge(to: card, cornerRadius: cornerRadius, halo: halo)
        card.layer?.backgroundColor = background.cgColor
        FloatShadow.applyShadow(to: card)  // masksToBounds stays off so the shadow isn't clipped
    }

    /// Corners and border for a card that hosts a **terminal**, whose fill and elevation shadow
    /// belong to the host instead: `background-alpha` governs both, and neither survives being done
    /// from a layer. An opaque fill cancels the surface's alpha out exactly (the chrome background
    /// IS the colour the terminal blends toward), and a layer shadow washes the interior, because
    /// Core Animation *fills* `shadowPath`. `SurfaceFloatOverlay` paints them with a `RingFillView`
    /// and an `OutsideShadowView`, and takes no `background` here because it re-derives
    /// its own from the live theme and alpha rather than freezing one at construction.
    static func applyTerminalHost(to card: NSView, cornerRadius: CGFloat, halo: Bool) {
        applyEdge(to: card, cornerRadius: cornerRadius, halo: halo)
        card.layer?.masksToBounds = false  // the host's shadow view reaches past the card
    }

    static func reapplyTheme(to card: NSView, halo: Bool = false) {
        card.layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        card.layer?.borderColor = borderColor(halo: halo)
    }

    /// The border alone, for a terminal host. Its fill is re-derived by the host from the live
    /// `background-alpha`, so writing one here would stamp over it.
    static func reapplyEdge(to card: NSView, halo: Bool) {
        card.layer?.borderColor = borderColor(halo: halo)
    }

    private static func applyEdge(to card: NSView, cornerRadius: CGFloat, halo: Bool) {
        card.wantsLayer = true
        card.layer?.cornerRadius = cornerRadius
        card.layer?.borderWidth = halo ? 1.5 : 1
        card.layer?.borderColor = borderColor(halo: halo)
    }

    private static func borderColor(halo: Bool) -> CGColor {
        halo ? Theme.current.chrome.accent.nsColor.cgColor : FloatShadow.edge.cgColor
    }
}

/// The behavior-critical dismissal latch shared by every modal overlay. Once an exit animation
/// starts, a second `animateOut` is ignored (idempotent), and `hitTest` reads `isDismissing` to
/// stop intercepting clicks — so a tap during the spring-out falls through to the terminal instead
/// of the vanishing backdrop. This idiom lived hand-copied in every overlay; a single miss would
/// swallow a click or double-run an exit.
struct DismissGate {
    private(set) var isDismissing = false

    /// Begin dismissing; returns `false` if it was already dismissing (the caller should bail).
    mutating func begin() -> Bool {
        guard !isDismissing else { return false }
        isDismissing = true
        return true
    }
}

/// Esc for a modal card, in one place: every card root routes its Esc through here, so the rule
/// lives once instead of in ~8 hand-written `.escape` cases that drifted apart.
///
/// It closes the CARD only, and that's the whole job. Layered dismissal (close an open popover
/// first, the card second) is NOT handled here and doesn't need to be: a bare Esc reaches the
/// focused control's `keyDown` before this `performKeyEquivalent` pass ever runs, so a popover host
/// (`Dropdown`, `IconPickerField`) closes its own list/grid there and the card never sees that Esc.
/// The two earlier attempts to close the popover from the card root failed for a dull
/// reason, now confirmed in the running app: `performKeyEquivalent` is simply not invoked
/// for a bare Esc while a popover host holds focus, so that code never ran. A popover owns its Esc
/// locally, in its `keyDown` — keep it there.
enum ModalEscape {
    /// `dismissing` is required, not defaulted: claiming Esc window-wide is only safe while the card
    /// is actually up, and "every root remembers the guard" is the exact drift this type exists to
    /// end. See the reasons a card declines below.
    static func handle(_ event: NSEvent, in window: NSWindow?, dismissing: Bool, close: () -> Void)
        -> Bool
    {
        guard KeyboardFocus.key(for: event) == .escape else { return false }
        // 1. Already springing out. The host clears its modal slot and presents the replacement
        //    synchronously, so for the length of the exit animation both cards sit in the
        //    contentView — and this traversal reaches the outgoing one first (lower subview index).
        //    Declining lets the Esc fall through to whatever replaced it: the new card, or a tool
        //    float's live PTY, where Esc belongs to vim. `hitTest` declines clicks for this reason.
        guard !dismissing else { return false }
        // 2. An IME is composing: cancelling the marked text owns that Esc, and claiming it here
        //    would discard the composition AND close the card, losing the typed query.
        if let editor = window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        close()
        return true
    }
}

/// A transparent backdrop filling the tile region; a click anywhere on it (outside the card)
/// dismisses. No dimming — the terminal stays visible behind the card.
final class BackdropView: NSView {
    private let onClick: () -> Void
    init(onClick: @escaping () -> Void) { self.onClick = onClick; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func mouseDown(with event: NSEvent) { onClick() }
}

/// A flipped document view so a scroll view's offsets and `scrollToVisible` are top-down — a
/// non-flipped document opens scrolled to the bottom. Shared by the modal card lists (the
/// command palette / repo picker and the Settings sections).
final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A scroller pinned to the slim overlay style, so a modal card's list keeps a thin, auto-hiding
/// bar even when the system "Show scroll bars: Always" setting would otherwise force the wide
/// legacy track once the list overflows.
final class SlimScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set {}
    }
}
