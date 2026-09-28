import AppKit

protocol ModalOverlay: NSView {
    func focusInitialResponder()
    func animateIn()
    func animateOut(completion: @escaping () -> Void)
    func reapplyTheme()
    var isShowingOverlaidCard: Bool { get }
}

extension ModalOverlay {
    func reapplyTheme() {}
    var isShowingOverlaidCard: Bool { false }
}

/// Swallows clicks so a tap on the card doesn't reach the dismissing backdrop.
final class CardView: ShadowCardView {
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
}

enum CardChrome {
    static let cornerRadius: CGFloat = 12

    static func apply(
        to card: NSView, background: NSColor, cornerRadius: CGFloat = CardChrome.cornerRadius,
        halo: Bool = false
    ) {
        applyEdge(to: card, cornerRadius: cornerRadius, halo: halo)
        card.layer?.backgroundColor = background.cgColor
        FloatShadow.applyShadow(to: card)
    }

    /// Leaves fill and shadow to the host: an opaque fill cancels `background-alpha`, and CA fills `shadowPath`.
    static func applyTerminalHost(to card: NSView, cornerRadius: CGFloat, halo: Bool) {
        applyEdge(to: card, cornerRadius: cornerRadius, halo: halo)
        card.layer?.masksToBounds = false
    }

    static func reapplyTheme(to card: NSView, halo: Bool = false) {
        card.layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        card.layer?.borderColor = borderColor(halo: halo)
    }

    static func reapplyEdge(to card: NSView, halo: Bool) {
        card.layer?.borderWidth = halo ? 1.5 : 1
        card.layer?.borderColor = borderColor(halo: halo)
    }

    private static func applyEdge(to card: NSView, cornerRadius: CGFloat, halo: Bool) {
        card.wantsLayer = true
        card.layer?.cornerRadius = cornerRadius
        reapplyEdge(to: card, halo: halo)
    }

    private static func borderColor(halo: Bool) -> CGColor {
        halo ? Theme.current.chrome.accent.nsColor.cgColor : FloatShadow.edge.cgColor
    }
}

struct DismissGate {
    private(set) var isDismissing = false

    mutating func begin() -> Bool {
        guard !isDismissing else { return false }
        isDismissing = true
        return true
    }
}

/// Popovers close in their own `keyDown`: `performKeyEquivalent` never sees a bare Esc while one holds focus.
enum ModalEscape {
    /// Declines during spring-out and IME composition, so Esc reaches the replacement card or the marked text.
    static func handle(_ event: NSEvent, in window: NSWindow?, dismissing: Bool, close: () -> Void)
        -> Bool
    {
        guard KeyboardFocus.key(for: event) == .escape else { return false }
        guard !dismissing else { return false }
        if let editor = window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        close()
        return true
    }
}

final class BackdropView: NSView {
    private let onClick: () -> Void
    init(onClick: @escaping () -> Void) { self.onClick = onClick; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func mouseDown(with event: NSEvent) { onClick() }

    // The pane underneath claims the whole canvas for its I-beam, and a cursor rect is not occluded by being covered.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// Flipped so a scroll view opens at the top rather than the bottom.
final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Keeps the overlay style even when "Show scroll bars: Always" would force the legacy track.
final class SlimScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set {}
    }
}
