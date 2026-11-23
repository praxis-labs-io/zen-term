import AppKit

/// Owners close it from `viewDidMoveToWindow`: the card lives on the content view and outlives a torn-out ancestor.
@MainActor
final class ListPopover {
    struct Row {
        let view: NSView
        let height: CGFloat
    }

    private struct Press: Sendable {
        let isKey: Bool
        let isEscape: Bool
        let windowNumber: Int
        let location: NSPoint

        init(_ event: NSEvent) {
            isKey = event.type == .keyDown
            isEscape = isKey && KeyboardFocus.key(for: event) == .escape
            windowNumber = event.windowNumber
            location = event.locationInWindow
        }
    }

    private unowned let anchor: NSView
    /// Swallows a click on the anchor: a toggle's own click would reopen the list it just closed.
    private let anchorToggles: Bool
    private var card: PopoverCard?
    private weak var scroll: FadingScrollView?
    private var resizeObserver: NSObjectProtocol?
    private var dismissObservers: [NSObjectProtocol] = []
    private var monitor: Any?

    var onSelfClose: (() -> Void)?
    var absorbsEscape: (() -> Bool)?

    private static let minWidth: CGFloat = 180
    private static let maxHeight: CGFloat = 260
    private static let verticalInset: CGFloat = ChromeMetrics.Spacing.s6
    private static let horizontalInset: CGFloat = ChromeMetrics.Spacing.s8
    private static let rowSpacing: CGFloat = ChromeMetrics.Spacing.s2
    private static let gap: CGFloat = ChromeMetrics.Spacing.s4
    private static let margin: CGFloat = ChromeMetrics.Spacing.s8
    /// Overlay scrollers draw over content, so without this lane the bar covers the content's trailing edge.
    private static let scrollerGutter: CGFloat = ChromeMetrics.Spacing.s16

    init(anchor: NSView, anchorToggles: Bool = false) {
        self.anchor = anchor
        self.anchorToggles = anchorToggles
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        dismissObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    var isOpen: Bool { card != nil }

    var cardFrame: NSRect { card?.frame ?? .zero }

    var cardForTesting: NSView? { card }

    func filterForTesting(_ event: NSEvent) -> NSEvent? { swallows(Press(event)) ? nil : event }

    func open(rows: [Row]) {
        guard let (window, contentView) = openingContext() else { return }
        present(rowsCard(rows), in: window, on: contentView)
    }

    func open(content: NSView) {
        guard let (window, contentView) = openingContext() else { return }
        present(contentCard(content, in: contentView), in: window, on: contentView)
    }

    /// Skips the entrance motion, or every keystroke of a filter would flash the card.
    func replace(rows: [Row]) {
        guard let contentView = unmountForReplace() else { return }
        mount(rowsCard(rows), on: contentView)
    }

    func replace(content: NSView) {
        guard let contentView = unmountForReplace() else { return }
        mount(contentCard(content, in: contentView), on: contentView)
    }

    private func unmountForReplace() -> NSView? {
        guard let old = card, let contentView = anchor.window?.contentView else { return nil }
        old.removeFromSuperview()
        return contentView
    }

    private func rowsCard(_ rows: [Row]) -> PopoverCard {
        let (stack, contentHeight) = rowStack(rows)
        let (built, _) = assembleCard(around: stack)
        built.frame.size = anchoredSize(contentHeight: contentHeight)
        return built
    }

    private func contentCard(_ content: NSView, in contentView: NSView) -> PopoverCard {
        let (built, trailing) = assembleCard(around: content)
        let (size, scrolls) = naturalSize(of: content, in: contentView)
        built.frame.size = size
        if scrolls { trailing.constant -= Self.scrollerGutter }
        return built
    }

    func reveal(_ row: NSView) { scroll?.reveal(row) }

    func close() {
        guard let card else { return }
        self.card = nil
        stopDismissing()
        card.isClosing = true
        Motion.springScaleFade(card, appearing: false) { [weak card] in card?.removeFromSuperview() }
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

    private func present(_ built: PopoverCard, in window: NSWindow, on contentView: NSView) {
        mount(built, on: contentView)
        startDismissing(in: window)
        Motion.springScaleFade(built, appearing: true)
    }

    private func mount(_ built: PopoverCard, on contentView: NSView) {
        contentView.addSubview(built)
        card = built
        reposition()
    }

    /// Observes resize with `queue: nil`, which runs synchronously; a queue would leave the card stranded for a turn.
    private func startDismissing(in window: NSWindow) {
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        dismissObservers = HoverCardView.windowDismissObservers(in: window) { [weak self] in self?.dismiss() }
        let dismissingEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: dismissingEvents) { [weak self] event in
            let press = Press(event)
            return MainActor.assumeIsolated { self?.swallows(press) ?? false } ? nil : event
        }
    }

    private func stopDismissing() {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        dismissObservers.forEach { NotificationCenter.default.removeObserver($0) }
        dismissObservers = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func dismiss() {
        guard isOpen else { return }
        close()
        onSelfClose?()
    }

    private func swallows(_ press: Press) -> Bool {
        guard let card, let window = anchor.window, press.windowNumber == window.windowNumber,
            let contentView = window.contentView
        else { return false }
        if press.isKey {
            guard press.isEscape else { return false }
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            if absorbsEscape?() == true { return true }
            dismiss()
            return true
        }
        if card.frame.contains(contentView.convert(press.location, from: nil)) { return false }
        let hit = contentView.hitTest(contentView.superview?.convert(press.location, from: nil) ?? press.location)
        dismiss()
        return anchorToggles && hit?.isDescendant(of: anchor) == true
    }

    private func anchoredSize(contentHeight: CGFloat) -> NSSize {
        NSSize(
            width: max(anchor.bounds.width, Self.minWidth),
            height: min(contentHeight + Self.verticalInset * 2, Self.maxHeight))
    }

    private func naturalSize(of content: NSView, in contentView: NSView) -> (size: NSSize, scrolls: Bool) {
        content.layoutSubtreeIfNeeded()
        let fitting = content.fittingSize
        let natural = NSSize(
            width: fitting.width + Self.horizontalInset * 2, height: fitting.height + Self.verticalInset * 2)
        let height = min(natural.height, contentView.bounds.height - Self.margin * 2)
        let scrolls = height < natural.height
        let width = natural.width + (scrolls ? Self.scrollerGutter : 0)
        return (NSSize(width: width, height: height), scrolls)
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

    private func assembleCard(around content: NSView) -> (card: PopoverCard, trailing: NSLayoutConstraint) {
        content.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(content)

        let scroll = FadingScrollView(document: doc)
        self.scroll = scroll

        let card = PopoverCard()
        CardChrome.apply(to: card, tier: .overlay)
        card.translatesAutoresizingMaskIntoConstraints = true
        card.addSubview(scroll)

        let trailing = content.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -Self.horizontalInset)
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
            trailing,
            content.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -Self.verticalInset),
        ])
        return (card, trailing)
    }
}

/// A closing card still fades on screen, and a click landing on it must not choose a row of a list that is gone.
private final class PopoverCard: ShadowCardView {
    var isClosing = false

    override func hitTest(_ point: NSPoint) -> NSView? { isClosing ? nil : super.hitTest(point) }
}
