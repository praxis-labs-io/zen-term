import AppKit

/// Shows one `LinkPreviewView` near the pointer while the terminal reports a hovered link
/// (Cmd+hover, the same gate that underlines it), and clears it when the report clears. Shared
/// like `TooltipPresenter` so only one preview is ever live, but undelayed — it must appear in
/// the same beat as libghostty's underline — and point-anchored, because the report arrives as a
/// surface action with no `NSEvent` to carry a location.
final class LinkPreviewPresenter {
    static let shared = LinkPreviewPresenter()
    private init() {}

    /// Clears the pointer's own footprint: flush against the pointer, the card sits under the
    /// arrow it is meant to float beside.
    private static let gap: CGFloat = 14

    private var preview: LinkPreviewView?
    private var shownURL: String?
    /// The surface's host view the current preview belongs to — a stale clear from a previously
    /// hovered pane must not tear down a newer pane's preview (pane-to-pane moves deliver the old
    /// pane's exit and the new pane's hover in no guaranteed order).
    private weak var owner: NSView?
    private var dismissObservers: [NSObjectProtocol] = []
    private var ownerWatch: Any?

    /// Reflect the hovered-link state a surface just reported: a URL shows (or replaces) the
    /// preview, nil clears it if `source` owns it. libghostty re-reports the same URL on every
    /// pointer move along a link, so an unchanged report keeps the card where it first appeared
    /// instead of dragging it under the pointer.
    func update(_ url: String?, near source: NSView) {
        dispatchPrecondition(condition: .onQueue(.main))  // fail fast on an accidental off-main call
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

        // The action carries no event, so read the pointer position directly.
        // Frame it directly (not via Auto Layout), so a later `layout()` on the content view
        // can't reset an unconstrained card to the origin.
        let pointer = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        card.translatesAutoresizingMaskIntoConstraints = true
        card.frame = HoverCardView.placementFrame(
            size: card.fittingSize, anchor: NSRect(origin: pointer, size: .zero),
            in: content, gap: Self.gap)
        preview = card
        shownURL = url
        owner = source
        installDismissTriggers(in: window)
    }

    /// Take the card down if its owner left the view hierarchy. Every close path that can run
    /// while a preview shows (⌘W on a pane or drawer is a Cmd chord, a float dismissal, a tab
    /// switch detaching the canvas) tears the owner down without a final nil report — the
    /// surface dies with it, or the controller's lookup no longer resolves it — so the clear
    /// that would have retired the card never arrives.
    func dismissIfOwnerDetached() {
        guard let preview else { return }
        let ownerIsLive =
            owner.map { $0.window === preview.window && !$0.isHiddenOrHasHiddenAncestor } ?? false
        if !ownerIsLive { teardown() }
    }

    /// Remove the preview and all its state. Safe to call when nothing is shown.
    private func teardown() {
        owner = nil
        shownURL = nil
        preview?.removeFromSuperview()
        preview = nil
        if let ownerWatch { NSEvent.removeMonitor(ownerWatch) }
        ownerWatch = nil
        dismissObservers.forEach { NotificationCenter.default.removeObserver($0) }
        dismissObservers = []
    }

    /// Window-level dismissals, plus the owner sweep. App deactivation is load-bearing, not
    /// parity polish: AppKit delivers the tracking exit with no matching re-enter
    /// (docs/swift-conventions.md), so libghostty may never send the empty-URL clear and the
    /// card would otherwise survive a Cmd-Tab away. The owner sweep runs on the next input
    /// event because no notification exists for "the owner left the hierarchy": a live owner
    /// makes it a no-op, a detached one takes the card down.
    private func installDismissTriggers(in window: NSWindow) {
        dismissObservers = HoverCardView.windowDismissObservers(in: window) { [weak self] in
            self?.teardown()
        }
        ownerWatch = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown,
                .flagsChanged, .scrollWheel,
            ]
        ) { [weak self] event in
            self?.dismissIfOwnerDetached()
            return event
        }
    }
}
