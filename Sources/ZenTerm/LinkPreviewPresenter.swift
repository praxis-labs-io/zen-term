import AppKit

final class LinkPreviewPresenter {
    static let shared = LinkPreviewPresenter()
    private init() {}

    private static let gap: CGFloat = 14

    private var preview: LinkPreviewView?
    private var shownURL: String?
    /// Pane-to-pane moves deliver the old exit and new hover in no guaranteed order.
    private weak var owner: NSView?
    private var dismissObservers: [NSObjectProtocol] = []
    private var ownerWatch: Any?

    /// An unchanged URL keeps the card put: libghostty re-reports it on every pointer move.
    func update(_ url: String?, near source: NSView) {
        dispatchPrecondition(condition: .onQueue(.main))
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

    func dismissIfOwnerDetached() {
        guard let preview else { return }
        let ownerIsLive =
            owner.map { $0.window === preview.window && !$0.isHiddenOrHasHiddenAncestor } ?? false
        if !ownerIsLive { teardown() }
    }

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

    /// Dismisses on deactivation: AppKit can drop the tracking exit, so libghostty never clears.
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
