import AppKit

// Replaces `NSView.toolTip`, so it reproduces the OS dismissal on keypress, focus loss and window close.
final class TooltipPresenter {
    static let shared = TooltipPresenter()
    private init() {}

    private static let delay: TimeInterval = 0.45
    private static let gap: CGFloat = 6

    private var tooltip: ChromeTooltip?
    // Guards against a stale `mouseExited` from a previous button tearing down a newer tooltip.
    private weak var owner: NSView?
    private var pending: DispatchWorkItem?
    private var keyMonitor: Any?
    private var dismissObservers: [NSObjectProtocol] = []

    func scheduleShow(
        for source: NSView, label: String, shortcut: String?, style: ChromeTooltip.Style = .line
    ) {
        teardown()
        owner = source
        let work = DispatchWorkItem { [weak self, weak source] in
            guard let self, let source, self.owner === source else { return }
            self.present(for: source, label: label, shortcut: shortcut, style: style)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    // A row whose copy changes under a live tooltip: replace it in place, since re-scheduling would blank it for the delay.
    func relabel(for source: NSView, label: String, shortcut: String?, style: ChromeTooltip.Style) {
        guard owner === source, tooltip != nil else { return }
        tooltip?.removeFromSuperview()
        tooltip = nil
        present(for: source, label: label, shortcut: shortcut, style: style)
    }

    func hide(for source: NSView) {
        guard owner === source else { return }
        teardown()
    }

    private func present(for source: NSView, label: String, shortcut: String?, style: ChromeTooltip.Style) {
        guard let window = source.window, let content = window.contentView else { return }
        let tip = ChromeTooltip(label: label, shortcut: shortcut, style: style)
        content.addSubview(tip)
        tip.layoutSubtreeIfNeeded()

        tip.translatesAutoresizingMaskIntoConstraints = true
        tip.frame = HoverCardView.placementFrame(
            size: tip.fittingSize,
            anchor: content.convert(source.bounds, from: source),
            in: content, gap: Self.gap)
        tooltip = tip
        installDismissTriggers(in: window)
    }

    private func teardown() {
        owner = nil
        pending?.cancel()
        pending = nil
        tooltip?.removeFromSuperview()
        tooltip = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        dismissObservers.forEach { NotificationCenter.default.removeObserver($0) }
        dismissObservers = []
    }

    var tooltipForTesting: ChromeTooltip? { tooltip }

    func dismissForTesting() { teardown() }

    private func installDismissTriggers(in window: NSWindow) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.teardown()
            return event
        }
        dismissObservers = HoverCardView.windowDismissObservers(in: window) { [weak self] in
            self?.teardown()
        }
    }
}
