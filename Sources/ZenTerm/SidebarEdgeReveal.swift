import AppKit

// Watches the window's left edge, so resting there floats the collapsed sidebar and leaving puts it away.
@MainActor
final class SidebarEdgeReveal {
    static var holdDelay: TimeInterval = 0.28
    static var exitGrace: TimeInterval = 0.12
    // A pointer aimed at the window edge comes to rest about 5pt in, so a thinner band never gets held.
    private static let restingWidth: CGFloat = 8
    // The pointer crosses the gutter on its way to the card, and an exit there would put it away mid-journey.
    private static var liveRegionWidth: CGFloat { ChromeMetrics.windowGutter + SidebarView.width }

    private let strip = EdgeStrip()
    private var stripWidth: NSLayoutConstraint?
    private var hold: DispatchWorkItem?
    private var grace: DispatchWorkItem?
    private var clickMonitor: Any?
    private var isPastTheWindowEdge = false
    private(set) var isRevealed = false
    var isSuppressed: () -> Bool = { true }
    var isPinned: () -> Bool = { false }
    var onReveal: () -> Void = {}
    var onHide: () -> Void = {}
    var onClickAway: () -> Void = {}
    var pointerIsInside: () -> Bool = { false }

    init() {
        strip.onEnter = { [weak self] in self?.pointerEntered() }
        strip.onMove = { [weak self] in self?.pointerMoved() }
        strip.onExit = { [weak self] offTheEdge in self?.pointerLeft(offTheEdge: offTheEdge) }
        pointerIsInside = { [weak strip] in strip?.pointerIsInside ?? false }
    }

    // Paint order is irrelevant to a view that draws nothing and refuses hits, and the canvas host owns the back.
    func install(in container: NSView) {
        container.addSubview(strip)
        let width = strip.widthAnchor.constraint(equalToConstant: Self.restingWidth)
        stripWidth = width
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            strip.topAnchor.constraint(equalTo: container.topAnchor),
            strip.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            width,
        ])
    }

    func setRevealed(_ revealed: Bool) {
        isRevealed = revealed
        if !revealed { isPastTheWindowEdge = false }
        cancelTimers()
        stripWidth?.constant = revealed ? Self.liveRegionWidth : Self.restingWidth
        strip.superview?.layoutSubtreeIfNeeded()
        strip.updateTrackingAreas()
        if revealed { addClickMonitor() } else { removeClickMonitor() }
    }

    func shutdown() {
        cancelTimers()
        removeClickMonitor()
    }

    // A pointer already inside when the window takes focus gets no `mouseEntered`, and a closing menu no event.
    func recheck() {
        guard isRevealed else { return }
        guard !isPinned() else {
            grace?.cancel()
            grace = nil
            return
        }
        if !pointerIsWithinReach { scheduleHide() }
    }

    private func pointerEntered() {
        isPastTheWindowEdge = false
        grace?.cancel()
        grace = nil
        guard !isRevealed, !isSuppressed() else { return }
        hold?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hold = nil
            guard !self.isRevealed, !self.isSuppressed(), self.pointerIsWithinReach else { return }
            self.onReveal()
        }
        hold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
    }

    // Overshooting the window's own edge is reaching for the card, not leaving it: the hold and the card both stand.
    // AppKit drops an enter when the pointer arrives inside the window's own resize band, so a move arms it too.
    private func pointerMoved() {
        guard !isRevealed, hold == nil else { return }
        pointerEntered()
    }

    private func pointerLeft(offTheEdge: Bool) {
        isPastTheWindowEdge = offTheEdge
        guard !offTheEdge else { return }
        hold?.cancel()
        hold = nil
        guard isRevealed else { return }
        scheduleHide()
    }

    private var pointerIsWithinReach: Bool {
        pointerIsInside() || (isPastTheWindowEdge && !isSuppressed())
    }

    private func scheduleHide() {
        grace?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRevealed, !self.isPinned(), !self.pointerIsWithinReach else { return }
            self.onHide()
        }
        grace = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitGrace, execute: work)
    }

    private func addClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.dismissIfClickMissedTheCard(event)
            return event
        }
    }

    private func removeClickMonitor() {
        guard let clickMonitor else { return }
        NSEvent.removeMonitor(clickMonitor)
        self.clickMonitor = nil
    }

    // Returns the event untouched, so the same click still lands in the pane it was aimed at.
    private func dismissIfClickMissedTheCard(_ event: NSEvent) {
        guard isRevealed, event.window === strip.window else { return }
        guard !strip.convert(strip.bounds, to: nil).contains(event.locationInWindow) else { return }
        cancelTimers()
        onClickAway()
    }

    private func cancelTimers() {
        hold?.cancel()
        hold = nil
        grace?.cancel()
        grace = nil
    }

    var stripForTesting: NSView { strip }
}

// Reports the pointer without taking it: tracking is geometric, so the panes underneath still get their clicks.
private final class EdgeStrip: NSView {
    var onEnter: () -> Void = {}
    var onMove: () -> Void = {}
    var onExit: (Bool) -> Void = { _ in }
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // `.activeInActiveApp`, matching the terminal's own area: tracking stops while the app is in back.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }

    override func mouseMoved(with event: NSEvent) { onMove() }

    override func mouseExited(with event: NSEvent) {
        onExit(leftPastTheWindowEdge(convert(event.locationInWindow, from: nil)))
    }

    private func leftPastTheWindowEdge(_ point: NSPoint) -> Bool {
        point.x <= bounds.minX && point.y > bounds.minY && point.y < bounds.maxY
    }
}
