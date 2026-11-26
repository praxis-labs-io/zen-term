import AppKit

final class ToastPresenter {
    private let pile = ToastPile()
    private let viewport = Viewport()
    /// A `var` so a `toast-duration` edit reaches a presenter built before it.
    private var dismissAfter: TimeInterval
    private let topConstraint: NSLayoutConstraint
    private let trailingConstraint: NSLayoutConstraint

    // Room inside the viewport's clip for a card's shadow, which falls downward.
    private static let shadowRoom = FloatShadow.Tier.float.blur
    private static let shadowFall = shadowRoom - FloatShadow.Tier.float.offset.height
    // Defaults to yes, so a caller that cannot tell whether you are here keeps today's behavior.
    private let isPresent: () -> Bool
    private let waitingForYou = NSHashTable<ToastView>.weakObjects()
    private let countdowns = NSMapTable<ToastView, DispatchWorkItem>.weakToStrongObjects()
    private var presenceObservers: [NSObjectProtocol] = []

    init(
        host: NSView, below: NSView? = nil, floor: NSLayoutYAxisAnchor? = nil, topInset: CGFloat,
        trailingInset: CGFloat, dismissAfter: TimeInterval = Motion.Linger.toast,
        isPresent: @escaping () -> Bool = { true }
    ) {
        self.dismissAfter = dismissAfter
        self.isPresent = isPresent
        host.addSubview(viewport, positioned: below == nil ? .above : .below, relativeTo: below)
        let document = viewport.mount(pile)
        topConstraint = pile.topAnchor.constraint(equalTo: document.topAnchor, constant: topInset)
        trailingConstraint = pile.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -trailingInset)
        NSLayoutConstraint.activate([
            topConstraint, trailingConstraint,
            viewport.topAnchor.constraint(equalTo: host.topAnchor),
            viewport.bottomAnchor.constraint(equalTo: floor ?? host.bottomAnchor),
            viewport.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            viewport.widthAnchor.constraint(equalTo: document.widthAnchor),
            pile.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.shadowRoom),
            document.bottomAnchor.constraint(equalTo: pile.bottomAnchor, constant: Self.shadowFall),
        ])
        pile.onClear = { [weak self] in self?.dismissAll() }
        pile.onUnfoldChange = { [weak self] unfolded in
            unfolded ? self?.pauseCountdowns() : self?.startCountdownsNowSomeoneIsHere()
        }
        for name in [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification] {
            presenceObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in self?.startCountdownsNowSomeoneIsHere()
                })
        }
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            presenceObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in self?.pauseCountdownsNowNobodyIsHere()
                })
        }
    }

    deinit {
        presenceObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func reapplyInsets(topInset: CGFloat, trailingInset: CGFloat) {
        topConstraint.constant = topInset
        trailingConstraint.constant = -trailingInset
    }

    func reapplyDuration(_ seconds: TimeInterval) { dismissAfter = seconds }

    func show(_ content: ToastContent) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.show(content) }
            return
        }
        let toast = ToastView(content: content)
        toast.onClose = { [weak self, weak toast] in
            guard let toast else { return }
            self?.dismiss(toast)
        }
        add(toast)
        armAutoDismiss(toast)
    }

    private func add(_ toast: ToastView) {
        pile.add(toast)
        enter(toast)
    }

    private func enter(_ view: NSView) {
        guard pile.isShowing(view), let edge = view.window?.contentView?.bounds.maxX else { return }
        let offscreen = edge - view.convert(view.bounds, to: nil).minX
        Motion.slideFade(view, appearing: true, from: CGVector(dx: offscreen, dy: 0))
    }

    private var countdownsHeld: Bool { !isPresent() || pile.isUnfolded }

    // A toast counts down only while you are in the window it is in, whether you were there when it
    // arrived or walked away halfway through. Coming back restarts it, so `auto` is always a whole
    // duration of your attention rather than whatever was left of it.
    private func armAutoDismiss(_ toast: ToastView) {
        guard !countdownsHeld else { return waitingForYou.add(toast) }
        let countdown = DispatchWorkItem { [weak self, weak toast] in
            guard let self, let toast else { return }
            self.countdowns.removeObject(forKey: toast)
            self.dismiss(toast)
        }
        countdowns.setObject(countdown, forKey: toast)
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter, execute: countdown)
    }

    private func startCountdownsNowSomeoneIsHere() {
        guard !countdownsHeld, waitingForYou.count > 0 else { return }
        let held = waitingForYou.allObjects
        waitingForYou.removeAllObjects()
        held.forEach(armAutoDismiss)
    }

    private func pauseCountdownsNowNobodyIsHere() {
        guard !isPresent() else { return }
        pauseCountdowns()
    }

    private func pauseCountdowns() {
        for toast in countdowns.keyEnumerator().allObjects.compactMap({ $0 as? ToastView }) {
            countdowns.object(forKey: toast)?.cancel()
            countdowns.removeObject(forKey: toast)
            waitingForYou.add(toast)
        }
    }

    @discardableResult
    func showSticky(
        _ content: ToastContent, actions: [ToastAction], showsClose: Bool = false,
        autoDismiss: Bool = false
    ) -> ToastView {
        dispatchPrecondition(condition: .onQueue(.main))
        let toast = ToastView(content: content, actions: actions, showsClose: showsClose)
        add(toast)
        if autoDismiss { armAutoDismiss(toast) }
        return toast
    }

    func present(card: ShadowCardView) {
        dispatchPrecondition(condition: .onQueue(.main))
        pile.add(card)
        enter(card)
    }

    func bringForward(card: ShadowCardView) {
        dispatchPrecondition(condition: .onQueue(.main))
        pile.bringForward(card)
    }

    func remove(card: ShadowCardView) {
        dispatchPrecondition(condition: .onQueue(.main))
        pile.release(card)
        Motion.springScaleFade(card, appearing: false) { [weak self, weak card] in
            guard let self, let card else { return }
            self.pile.remove(card)
        }
    }

    /// Excludes the surface-failure notice, whose only exits are Retry and Close Pane.
    private var dismissible: [ToastView] {
        pile.cards.compactMap { $0 as? ToastView }.filter { !$0.isDismissing && $0.onClose != nil }
    }

    @discardableResult
    func dismissOldest() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let toast = dismissible.first else { return false }
        toast.onClose?()
        return true
    }

    func dismissAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        dismissible.forEach { $0.onClose?() }
    }

    func dismiss(_ toast: ToastView) {
        countdowns.object(forKey: toast)?.cancel()
        countdowns.removeObject(forKey: toast)
        waitingForYou.remove(toast)
        guard !toast.isDismissing else { return }
        pile.release(toast)
        toast.animateOut { [weak self, weak toast] in
            guard let self, let toast else { return }
            self.pile.remove(toast)
            toast.onDismissed?()
        }
    }

    var pileForTesting: ToastPile { pile }
    var viewportForTesting: NSView { viewport }

    // A fixed height, so nothing jumps mid-animation: resizing a scroll view snaps its clip ahead of its frame.
    private final class Viewport: NSView {
        private let scroll = FadingScrollView()
        private weak var pile: ToastPile?

        init() {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = false
            scroll.verticalScrollElasticity = .none
            scroll.horizontalScrollElasticity = .none
            addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
                scroll.topAnchor.constraint(equalTo: topAnchor),
                scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func mount(_ pile: ToastPile) -> NSView {
            let document = FlippedView()
            document.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(pile)
            scroll.documentView = document
            NSLayoutConstraint.activate([
                document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            ])
            self.pile = pile
            return document
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let pile, let hit = super.hitTest(point), hit === pile || hit.isDescendant(of: pile) else {
                return nil
            }
            return hit
        }
    }
}
