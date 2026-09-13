import AppKit

/// Owners close it from `viewDidMoveToWindow`: the card lives on the content view and outlives a torn-out ancestor.
@MainActor
final class ListPopover {
    struct Row {
        let view: NSView
        let height: CGFloat
    }

    private unowned let anchor: NSView
    private var card: NSView?
    private var resizeObserver: NSObjectProtocol?

    var onSelfClose: (() -> Void)?

    private static let minWidth: CGFloat = 180
    private static let maxHeight: CGFloat = 260
    private static let verticalInset: CGFloat = 6
    private static let horizontalInset: CGFloat = 8
    private static let rowSpacing: CGFloat = 2
    private static let gap: CGFloat = 4
    private static let margin: CGFloat = 8

    init(anchor: NSView) {
        self.anchor = anchor
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }

    var isOpen: Bool { card != nil }

    var cardFrame: NSRect { card?.frame ?? .zero }

    /// Observes resize with `queue: nil`, which runs synchronously; a queue would leave the card stranded for a turn.
    func open(rows: [Row]) {
        guard card == nil, let window = anchor.window, let contentView = window.contentView else {
            return
        }
        let built = buildCard(rows: rows)
        contentView.addSubview(built)
        card = built
        reposition()
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: nil
        ) { [weak self] _ in
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

    func reposition() {
        guard let card, let contentView = anchor.window?.contentView else { return }
        card.layoutSubtreeIfNeeded()
        let size = card.frame.size
        let origin = anchor.convert(anchor.bounds, to: contentView)
        let x = max(Self.margin, min(origin.minX, contentView.bounds.width - size.width - Self.margin))
        let below = origin.minY - size.height - Self.gap
        let above = origin.maxY + Self.gap
        let maxY = max(Self.margin, contentView.bounds.height - size.height - Self.margin)
        var y = below
        if y < Self.margin { y = above }
        y = max(Self.margin, min(y, maxY))
        card.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Each row joins the stack before its width constraint, which throws without a common ancestor.
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
