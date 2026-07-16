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

    static func apply(to card: NSView, background: NSColor, cornerRadius: CGFloat = CardChrome.cornerRadius) {
        card.wantsLayer = true
        card.layer?.cornerRadius = cornerRadius
        card.layer?.backgroundColor = background.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = FloatShadow.edge.cgColor
        FloatShadow.applyShadow(to: card)  // masksToBounds stays off so the shadow isn't clipped
    }

    static func reapplyTheme(to card: NSView) {
        card.layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        card.layer?.borderColor = FloatShadow.edge.cgColor
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

/// A control that floats a popover of its own (a `Dropdown`'s list, an `IconPickerField`'s icon
/// grid) and so gets first refusal on Esc before the card it sits in closes. Both adopters open
/// their popover into `window.contentView` rather than into the card, so the card's subtree can't
/// be searched for it — the host control is the handle.
protocol PopoverHosting: NSView {
    var isPopoverOpen: Bool { get }
    func closePopover()
}

/// Esc for a modal card, in one place. Every card root claims Esc in `performKeyEquivalent` —
/// the only layer that runs before a cancel button's own `"\u{1b}"` key equivalent, which used to
/// win unconditionally and discard a half-filled form out from under an open popover.
enum ModalEscape {
    /// Esc, layered: an open popover claims it first, else the card closes. The open popover is
    /// always the first responder's — both hosts close theirs on `resignFirstResponder`, so the
    /// window already knows which one it is and no tree walk is needed.
    ///
    /// A `FieldBox`'s first responder is its field editor (an `NSTextView`), not the box — the cast
    /// simply fails and the card closes, which is what Esc in a text field should do.
    static func handle(_ event: NSEvent, in window: NSWindow?, close: () -> Void) -> Bool {
        guard KeyboardFocus.key(for: event) == .escape else { return false }
        if let host = window?.firstResponder as? PopoverHosting, host.isPopoverOpen {
            host.closePopover()
            return true
        }
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
