import AppKit

final class ToastPresenter {
    private let stack = NSStackView()
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
        dismissAfter: TimeInterval = 4, isPresent: @escaping () -> Bool = { true }
    ) {
        self.dismissAfter = dismissAfter
        self.isPresent = isPresent
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack, positioned: below == nil ? .above : .below, relativeTo: below)
        topConstraint = stack.topAnchor.constraint(equalTo: host.topAnchor, constant: topInset)
        trailingConstraint = stack.trailingAnchor.constraint(
            equalTo: host.trailingAnchor, constant: -trailingInset)
        NSLayoutConstraint.activate([topConstraint, trailingConstraint])
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
        stack.addArrangedSubview(toast)
        toast.animateIn()
        armAutoDismiss(toast)
    }

    // A toast counts down only while you are in the window it is in, whether you were there when it
    // arrived or walked away halfway through. Coming back restarts it, so `auto` is always a whole
    // duration of your attention rather than whatever was left of it.
    private func armAutoDismiss(_ toast: ToastView) {
        guard isPresent() else { return waitingForYou.add(toast) }
        let countdown = DispatchWorkItem { [weak self, weak toast] in
            guard let self, let toast else { return }
            self.countdowns.removeObject(forKey: toast)
            self.dismiss(toast)
        }
        countdowns.setObject(countdown, forKey: toast)
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter, execute: countdown)
    }

    private func startCountdownsNowSomeoneIsHere() {
        guard isPresent(), waitingForYou.count > 0 else { return }
        let held = waitingForYou.allObjects
        waitingForYou.removeAllObjects()
        held.forEach(armAutoDismiss)
    }

    private func pauseCountdownsNowNobodyIsHere() {
        guard !isPresent() else { return }
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
        let toast = ToastView(
            content: content, actions: actions, armsKeys: false, showsClose: showsClose)
        stack.addArrangedSubview(toast)
        toast.animateIn()
        if autoDismiss { armAutoDismiss(toast) }
        return toast
    }

    @discardableResult
    func confirm(_ content: ToastContent, actions: [ToastAction]) -> ToastView {
        let toast = ToastView(content: content, actions: actions)
        stack.addArrangedSubview(toast)
        toast.animateIn()
        return toast
    }

    func present(card: ShadowCardView) {
        dispatchPrecondition(condition: .onQueue(.main))
        stack.addArrangedSubview(card)
        card.superview?.layoutSubtreeIfNeeded()
        Motion.springScaleFade(card, appearing: true)
    }

    func remove(card: ShadowCardView) {
        dispatchPrecondition(condition: .onQueue(.main))
        Motion.springScaleFade(card, appearing: false) { [weak self, weak card] in
            guard let self, let card else { return }
            self.stack.removeArrangedSubview(card)
            card.removeFromSuperview()
        }
    }

    /// Excludes the surface-failure notice, whose only exits are Retry and Close Pane.
    private var dismissible: [ToastView] {
        stack.arrangedSubviews
            .compactMap { $0 as? ToastView }
            .filter { !$0.isDismissing && $0.onClose != nil }
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
        toast.animateOut { [weak self, weak toast] in
            guard let self, let toast else { return }
            self.removeCollapsing(toast)
        }
    }

    private func removeCollapsing(_ toast: ToastView) {
        defer { toast.onDismissed?() }
        guard !Motion.isReduceMotionEnabled() else {
            stack.removeArrangedSubview(toast)
            toast.removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            stack.removeArrangedSubview(toast)
            toast.removeFromSuperview()
            stack.layoutSubtreeIfNeeded()
        }
    }
}
