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
    private weak var scroll: FadingScrollView?
    private var resizeObserver: NSObjectProtocol?

    var onSelfClose: (() -> Void)?

    private static let minWidth: CGFloat = 180
    private static let maxHeight: CGFloat = 260
    private static let verticalInset: CGFloat = ChromeMetrics.Spacing.s6
    private static let horizontalInset: CGFloat = ChromeMetrics.Spacing.s8
    private static let rowSpacing: CGFloat = ChromeMetrics.Spacing.s2
    private static let gap: CGFloat = ChromeMetrics.Spacing.s4
    private static let margin: CGFloat = ChromeMetrics.Spacing.s8
    /// Overlay scrollers draw over content, so without this lane the bar covers the last column.
    private static let scrollerGutter: CGFloat = ChromeMetrics.Spacing.s16

    init(anchor: NSView) {
        self.anchor = anchor
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }

    var isOpen: Bool { card != nil }

    var cardFrame: NSRect { card?.frame ?? .zero }

    var cardForTesting: NSView? { card }

    func open(rows: [Row]) {
        guard let (window, contentView) = openingContext() else { return }
        let (stack, contentHeight) = rowStack(rows)
        let built = assembleCard(around: stack)
        built.frame.size = anchoredSize(contentHeight: contentHeight)
        present(built, in: window, on: contentView)
    }

    func open(content: NSView) {
        guard let (window, contentView) = openingContext() else { return }
        let built = assembleCard(around: content)
        built.frame.size = naturalSize(of: content, in: contentView)
        present(built, in: window, on: contentView)
    }

    func reveal(_ row: NSView) { scroll?.reveal(row) }

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

    private func openingContext() -> (NSWindow, NSView)? {
        guard card == nil, let window = anchor.window, let contentView = window.contentView else { return nil }
        return (window, contentView)
    }

    /// Observes resize with `queue: nil`, which runs synchronously; a queue would leave the card stranded for a turn.
    private func present(_ built: NSView, in window: NSWindow, on contentView: NSView) {
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

    private func anchoredSize(contentHeight: CGFloat) -> NSSize {
        NSSize(
            width: max(anchor.bounds.width, Self.minWidth),
            height: min(contentHeight + Self.verticalInset * 2, Self.maxHeight))
    }

    private func naturalSize(of content: NSView, in contentView: NSView) -> NSSize {
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        let natural = NSSize(
            width: fitting.width + Self.horizontalInset * 2, height: fitting.height + Self.verticalInset * 2)
        let height = min(natural.height, contentView.bounds.height - Self.margin * 2)
        let scrolls = height < natural.height
        return NSSize(width: natural.width + (scrolls ? Self.scrollerGutter : 0), height: height)
    }

    /// Each row joins the stack before its width constraint, which throws without a common ancestor.
    private func rowStack(_ rows: [Row]) -> (NSStackView, CGFloat) {
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
        return (stack, contentHeight)
    }

    private func assembleCard(around content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(content)

        let scroll = FadingScrollView(document: doc)
        self.scroll = scroll

        let card = ShadowCardView()
        CardChrome.apply(to: card, tier: .overlay)
        card.translatesAutoresizingMaskIntoConstraints = true
        card.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: doc.topAnchor, constant: Self.verticalInset),
            content.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: Self.horizontalInset),
            content.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -Self.horizontalInset),
            content.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -Self.verticalInset),
        ])
        return card
    }
}
