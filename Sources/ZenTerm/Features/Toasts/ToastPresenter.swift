import AppKit

final class ToastPresenter {
    private let pile = ToastPile()
    /// A `var` so a `toast-duration` edit reaches a presenter built before it.
    private var dismissAfter: TimeInterval
    private let topConstraint: NSLayoutConstraint
    private let trailingConstraint: NSLayoutConstraint
    // Defaults to yes, so a caller that cannot tell whether you are here keeps today's behavior.
    private let isPresent: () -> Bool
    private let waitingForYou = NSHashTable<ToastView>.weakObjects()
    private let countdowns = NSMapTable<ToastView, DispatchWorkItem>.weakToStrongObjects()
    private var presenceObservers: [NSObjectProtocol] = []

    init(
        host: NSView, below: NSView? = nil, topInset: CGFloat, trailingInset: CGFloat,
        dismissAfter: TimeInterval = Motion.Linger.toast, isPresent: @escaping () -> Bool = { true }
    ) {
        self.dismissAfter = dismissAfter
        self.isPresent = isPresent
        host.addSubview(pile, positioned: below == nil ? .above : .below, relativeTo: below)
        topConstraint = pile.topAnchor.constraint(equalTo: host.topAnchor, constant: topInset)
        trailingConstraint = pile.trailingAnchor.constraint(
            equalTo: host.trailingAnchor, constant: -trailingInset)
        NSLayoutConstraint.activate([topConstraint, trailingConstraint])
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
        if pile.isShowing(toast) { toast.animateIn() }
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
        if pile.isShowing(card) { Motion.springScaleFade(card, appearing: true) }
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
}
