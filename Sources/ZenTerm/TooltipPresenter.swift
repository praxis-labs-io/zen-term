import AppKit

/// Shows a single branded `ChromeTooltip` on hover: after a short delay, centered above its
/// trigger, clamped inside the window, and flipped below if it would clip the top edge. One
/// tooltip at a time — `IconButton` drives it from its own hover state. A shared presenter (rather
/// than a per-button window) so only one tooltip is ever live and a fast hover across a button row
/// doesn't stack them.
///
/// Because it replaces the OS-managed `NSView.toolTip`, it reproduces the native dismissal the OS
/// used to give for free: a shown tooltip is torn down on any keypress, on the window/app losing
/// key/active, and when the window closes — not only when the pointer leaves the trigger.
final class TooltipPresenter {
    static let shared = TooltipPresenter()
    private init() {}

    private static let delay: TimeInterval = 0.45
    private static let gap: CGFloat = 6

    private var tooltip: ChromeTooltip?
    /// The view the current (shown or pending) tooltip belongs to — guards against a stale
    /// `mouseExited` from a previously-hovered button tearing down a newer button's tooltip.
    private weak var owner: NSView?
    private var pending: DispatchWorkItem?
    private var keyMonitor: Any?
    private var dismissObservers: [NSObjectProtocol] = []

    /// Schedule a tooltip for `source`, superseding any pending or shown one. `shortcut` is resolved
    /// by the caller (e.g. from the live keymap) so it reflects the current binding.
    func scheduleShow(for source: NSView, label: String, shortcut: String?) {
        // Tear down any live tooltip now (not on its owner's exit, which may arrive after this
        // button's enter) so the previous button's label can't linger while this one is pending.
        teardown()
        owner = source
        let work = DispatchWorkItem { [weak self, weak source] in
            guard let self, let source, self.owner === source else { return }
            self.present(for: source, label: label, shortcut: shortcut)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    /// Dismiss the tooltip if `source` owns it (else a no-op, so an old button's exit can't close a
    /// newer button's tooltip).
    func hide(for source: NSView) {
        guard owner === source else { return }
        teardown()
    }

    private func present(for source: NSView, label: String, shortcut: String?) {
        guard let window = source.window, let content = window.contentView else { return }
        let tip = ChromeTooltip(label: label, shortcut: shortcut)
        content.addSubview(tip)
        tip.layoutSubtreeIfNeeded()

        // Frame it directly (not via Auto Layout), so a later `layout()` on the content view can't
        // reset an unconstrained tooltip to the origin.
        tip.translatesAutoresizingMaskIntoConstraints = true
        tip.frame = HoverCardView.placementFrame(
            size: tip.fittingSize,
            anchor: content.convert(source.bounds, from: source),  // trigger rect in content space
            in: content, gap: Self.gap)
        tooltip = tip
        installDismissTriggers(in: window)
    }

    /// Remove the tooltip and all its state — pending show, view, and dismissal hooks. Safe to call
    /// when nothing is shown.
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

    /// Any keypress, or the window/app losing focus, or the window closing, dismisses the tooltip —
    /// parity with the native `toolTip`, which the OS tore down on these.
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
