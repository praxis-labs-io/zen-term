import AppKit

/// Shows one `LinkPreviewView` near the pointer while the terminal reports a hovered link
/// (Cmd+hover, the same gate that underlines it), and clears it when the report clears. Shared
/// like `TooltipPresenter` so only one preview is ever live, but undelayed — it must appear in
/// the same beat as libghostty's underline — and point-anchored, because the report arrives as a
/// surface action with no `NSEvent` to carry a location (ZEN-24).
final class LinkPreviewPresenter {
    static let shared = LinkPreviewPresenter()
    private init() {}

    /// Clears the pointer's own footprint: flush against the pointer, the card sits under the
    /// arrow it is meant to float beside.
    private static let gap: CGFloat = 14
    private static let margin: CGFloat = 8

    private var preview: LinkPreviewView?
    private var shownURL: String?
    /// The surface's host view the current preview belongs to — a stale clear from a previously
    /// hovered pane must not tear down a newer pane's preview (pane-to-pane moves deliver the old
    /// pane's exit and the new pane's hover in no guaranteed order).
    private weak var owner: NSView?
    private var dismissObservers: [NSObjectProtocol] = []

    var shownURLForTesting: String? { shownURL }

    /// Reflect the hovered-link state a surface just reported: a URL shows (or replaces) the
    /// preview, nil clears it if `source` owns it. libghostty re-reports the same URL on every
    /// pointer move along a link, so an unchanged report keeps the card where it first appeared
    /// instead of dragging it under the pointer.
    func update(_ url: String?, near source: NSView) {
        guard let url else {
            if owner === source { teardown() }
            return
        }
        if owner === source, shownURL == url, preview != nil { return }
        teardown()
        guard let window = source.window, let content = window.contentView else { return }

        let card = LinkPreviewView(url: url)
        content.addSubview(card)
        card.layoutSubtreeIfNeeded()
        let size = card.fittingSize

        // The action carries no event, so read the pointer directly (the ZEN-310 primitive).
        let pointer = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        var x = pointer.x - size.width / 2
        x = max(Self.margin, min(x, content.bounds.width - size.width - Self.margin))

        // Sit above the pointer so the card never covers the link being read; the "up" direction
        // and the clip test depend on the content view's flippedness. Flip to below if the card
        // would run off the visual top edge.
        let y: CGFloat
        if content.isFlipped {
            let above = pointer.y - Self.gap - size.height
            y = above < Self.margin ? pointer.y + Self.gap : above
        } else {
            let above = pointer.y + Self.gap
            y =
                above + size.height > content.bounds.height - Self.margin
                ? pointer.y - Self.gap - size.height : above
        }

        // Frame it directly (not via Auto Layout), so a later `layout()` on the content view
        // can't reset an unconstrained card to the origin.
        card.translatesAutoresizingMaskIntoConstraints = true
        card.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        preview = card
        shownURL = url
        owner = source
        installDismissTriggers(in: window)
    }

    /// Remove the preview and all its state. Safe to call when nothing is shown.
    private func teardown() {
        owner = nil
        shownURL = nil
        preview?.removeFromSuperview()
        preview = nil
        dismissObservers.forEach { NotificationCenter.default.removeObserver($0) }
        dismissObservers = []
    }

    /// The window losing key, closing, or the app deactivating dismisses the preview. App
    /// deactivation is load-bearing, not parity polish: AppKit delivers the tracking exit with no
    /// matching re-enter (docs/swift-conventions.md), so libghostty may never send the empty-URL
    /// clear and the card would otherwise survive a Cmd-Tab away.
    private func installDismissTriggers(in window: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            dismissObservers.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.teardown()
                })
        }
        dismissObservers.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.teardown() })
    }
}
