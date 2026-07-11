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
}

/// The card container: swallows clicks so a tap on the card's empty area doesn't fall through
/// to the backdrop (which would dismiss). Shared by every modal card.
final class CardView: NSView { override func mouseDown(with event: NSEvent) {} }

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
