import AppKit

/// The floating list behind a popover button: card assembly, placement, and the lifetime that
/// keeps a card from outliving the button that opened it. `Dropdown` and `CheckboxDropdown`
/// compose one each and supply their own rows.
///
/// Not `ChromePopover`, which is the other floating primitive here and answers a different question:
/// that one wraps one caller-supplied view, anchors it above a trigger with constraints, and dismisses
/// on a click-outside backdrop. A dropdown list places itself below its button and flips above near
/// the window's bottom, sizes and caps a scrolling column of rows, and dismisses on Esc, on a pick, or
/// on losing focus, with no backdrop to swallow the click that opened it.
///
/// Follows `KeybindHintBubble`'s window-child pattern. The card is parented to the window's
/// **content view**, not to the button's subtree, so it escapes the button's bounds and can draw
/// over anything. That is also what makes closing it the owner's job: tearing out an ancestor,
/// the Settings modal on a tab switch, does not take the card with it, and a stranded card sits
/// over every tab forever. Every owner closes from `viewDidMoveToWindow` when the window goes nil.
@MainActor
final class ListPopover {
    /// One line of the list: a row, or a group header. The popover sizes it and stretches it to
    /// the card's width; what it draws is the owner's business.
    struct Row {
        let view: NSView
        let height: CGFloat
    }

    /// The button the list hangs off. `unowned` rather than `weak`: the button owns this, so it
    /// cannot outlive it, and every method here is reached from the button.
    private unowned let anchor: NSView
    private var card: NSView?
    private var resizeObserver: NSObjectProtocol?

    /// Called when the list closes itself rather than being closed by the owner, so the owner can
    /// drop the lit border its button wears while open.
    var onSelfClose: (() -> Void)?

    /// Narrower than this and a list of theme names reads as a column of ellipses.
    private static let minWidth: CGFloat = 180
    private static let maxHeight: CGFloat = 260
    /// Padding inside the card, above the first row and below the last.
    private static let verticalInset: CGFloat = 6
    private static let horizontalInset: CGFloat = 8
    private static let rowSpacing: CGFloat = 2
    /// The gap between the button and the card, and the smallest gap allowed to a window edge.
    private static let gap: CGFloat = 4
    private static let margin: CGFloat = 8

    init(anchor: NSView) {
        self.anchor = anchor
    }

    /// Backstop for a control torn down with its list still up: `close()` is what normally drops the
    /// observer, and nothing runs it when the owner is deallocated outright.
    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }

    var isOpen: Bool { card != nil }

    /// Test hook: where the card landed, in window coordinates. Size alone cannot tell a card
    /// placed below the button from one that ran off the bottom of the window.
    var cardFrame: NSRect { card?.frame ?? .zero }

    /// Build the card from `rows`, put it on the window's content view, and place it. A no-op when
    /// a card is already up, or when the button is not in a window.
    func open(rows: [Row]) {
        guard card == nil, let window = anchor.window, let contentView = window.contentView else {
            return
        }
        let built = buildCard(rows: rows)
        contentView.addSubview(built)
        card = built
        reposition()
        // The card is frame-driven and placed once, so a resize leaves it stranded where the button
        // used to be. Close instead of chasing the anchor: that is what a menu does, and following a
        // live resize would re-run the flip-above decision on every frame of the drag.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            // `queue: .main`, so this is already the main thread — assert it rather than hop, so the
            // list is gone in the same turn as the resize.
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                self.close()
                self.onSelfClose?()
            }
        }
    }

    func close() {
        card?.removeFromSuperview()
        card = nil
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
    }

    /// Frame the card below the button, flipping above when there is no room, and clamp it inside
    /// the window either way.
    func reposition() {
        guard let card, let contentView = anchor.window?.contentView else { return }
        card.layoutSubtreeIfNeeded()
        let size = card.frame.size
        let origin = anchor.convert(anchor.bounds, to: contentView)
        let x = max(Self.margin, min(origin.minX, contentView.bounds.width - size.width - Self.margin))
        // contentView is not flipped: below the button = a smaller y. Prefer below; if that runs
        // off the bottom, flip above, then clamp so the card never draws outside the window.
        let below = origin.minY - size.height - Self.gap
        let above = origin.maxY + Self.gap
        let maxY = max(Self.margin, contentView.bounds.height - size.height - Self.margin)
        var y = below
        if y < Self.margin { y = above }
        y = max(Self.margin, min(y, maxY))
        card.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func buildCard(rows: [Row]) -> NSView {
        let chrome = Theme.current.chrome
        let width = max(anchor.bounds.width, Self.minWidth)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        var contentHeight: CGFloat = 0
        for row in rows {
            if contentHeight > 0 { contentHeight += stack.spacing }
            // Added to the stack BEFORE relating its width to the stack's — the cross-view
            // constraint needs a common ancestor, and activating it first throws, which aborts the
            // whole card build.
            stack.addArrangedSubview(row.view)
            row.view.heightAnchor.constraint(equalToConstant: row.height).isActive = true
            row.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            contentHeight += row.height
        }

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = SlimScroller()
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let card = ShadowCardView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = chrome.background.nsColor.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = FloatShadow.edge.cgColor
        // Frame-driven: positioned AND sized by frame in `reposition()`. An unconstrained origin
        // under `false` can be dropped on a layout pass, so the card owns its own frame rather
        // than relying on width/height constraints.
        card.translatesAutoresizingMaskIntoConstraints = true
        FloatShadow.applyShadow(to: card)
        card.addSubview(scroll)

        let inset = Self.verticalInset
        let cardHeight = min(contentHeight + inset * 2, Self.maxHeight)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: inset),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: Self.horizontalInset),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -Self.horizontalInset),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -inset),
        ])
        card.frame = NSRect(x: 0, y: 0, width: width, height: cardHeight)
        return card
    }
}
