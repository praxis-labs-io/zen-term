import AppKit

/// Shows a single branded `ChromeTooltip` on hover: after a short delay, centered above its
/// trigger, clamped inside the window, and flipped below if it would clip the top edge. One
/// tooltip at a time — `IconButton` drives it from its own hover state. A shared presenter (rather
/// than a per-button window) so only one tooltip is ever live and a fast hover across a button row
/// doesn't stack them.
final class TooltipPresenter {
    static let shared = TooltipPresenter()
    private init() {}

    private static let delay: TimeInterval = 0.45
    private static let gap: CGFloat = 6
    private static let margin: CGFloat = 8

    private var tooltip: ChromeTooltip?
    /// The view the current (shown or pending) tooltip belongs to — guards against a stale
    /// `mouseExited` from a previously-hovered button tearing down a newer button's tooltip.
    private weak var owner: NSView?
    private var pending: DispatchWorkItem?

    /// Schedule a tooltip for `source`, superseding any pending one. `shortcut` is resolved by the
    /// caller (e.g. from the live keymap) so it reflects the current binding.
    func scheduleShow(for source: NSView, label: String, shortcut: String?) {
        owner = source
        pending?.cancel()
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
        owner = nil
        pending?.cancel()
        pending = nil
        tooltip?.removeFromSuperview()
        tooltip = nil
    }

    private func present(for source: NSView, label: String, shortcut: String?) {
        guard let window = source.window, let content = window.contentView else { return }
        tooltip?.removeFromSuperview()
        let tip = ChromeTooltip(label: label, shortcut: shortcut)
        content.addSubview(tip)
        tip.layoutSubtreeIfNeeded()
        let size = tip.fittingSize

        let anchor = content.convert(source.bounds, from: source)  // trigger rect in content space
        var x = anchor.midX - size.width / 2
        x = max(Self.margin, min(x, content.bounds.width - size.width - Self.margin))

        // Sit above the trigger; the "up" direction and the clip test depend on the content view's
        // flippedness. Flip to below if the tooltip would run off the visual top edge.
        let y: CGFloat
        if content.isFlipped {
            let above = anchor.minY - Self.gap - size.height
            y = above < Self.margin ? anchor.maxY + Self.gap : above
        } else {
            let above = anchor.maxY + Self.gap
            y =
                above + size.height > content.bounds.height - Self.margin
                ? anchor.minY - Self.gap - size.height : above
        }

        tip.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        tooltip = tip
    }
}
