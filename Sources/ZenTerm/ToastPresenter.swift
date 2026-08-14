import AppKit

/// Presents transient toasts stacked in the top-right of a host view. Each springs in,
/// auto-dismisses after a delay (or on click), and springs out. Window-level and content-
/// agnostic, so anything that needs to surface a brief notice can reuse it.
final class ToastPresenter {
    private let stack = NSStackView()
    /// How long an auto-dismissing toast stays up. A `var` because the presenter is built lazily on
    /// the first toast and then lives for the window: baked at init, a `toast-duration` edit would
    /// never reach a window that had already shown one.
    private var dismissAfter: TimeInterval
    /// The two insets, held so a `window-gutter` / `window-chrome` change can re-point them. The
    /// presenter is built lazily on the first toast, so without this the stack keeps whatever the
    /// metrics were at that moment for the life of the window.
    private let topConstraint: NSLayoutConstraint
    private let trailingConstraint: NSLayoutConstraint

    /// `below` is a view the stack must not cover — a modal card already open when the first toast of
    /// the window's life fires. Nil puts the stack at the front, above the mounted canvas.
    init(
        host: NSView, below: NSView? = nil, topInset: CGFloat, trailingInset: CGFloat,
        dismissAfter: TimeInterval = 4
    ) {
        self.dismissAfter = dismissAfter
        stack.orientation = .vertical
        stack.alignment = .trailing  // new toasts stack downward, right-aligned
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack, positioned: below == nil ? .above : .below, relativeTo: below)
        topConstraint = stack.topAnchor.constraint(equalTo: host.topAnchor, constant: topInset)
        trailingConstraint = stack.trailingAnchor.constraint(
            equalTo: host.trailingAnchor, constant: -trailingInset)
        NSLayoutConstraint.activate([topConstraint, trailingConstraint])
    }

    /// Re-point the stack's insets after a chrome-layout change — no relaunch. Takes the resolved
    /// values rather than reading `ChromeMetrics` itself, so the presenter stays content-agnostic
    /// and the caller keeps owning the `+ 12` it offsets them by.
    func reapplyInsets(topInset: CGFloat, trailingInset: CGFloat) {
        topConstraint.constant = topInset
        trailingConstraint.constant = -trailingInset
    }

    /// Re-point how long an auto-dismissing toast stays up after a `toast-duration` edit. Takes the
    /// resolved seconds rather than reading the config, keeping the presenter content-agnostic.
    /// Applies to the next toast; one already counting down keeps the deadline it was armed with.
    func reapplyDuration(_ seconds: TimeInterval) { dismissAfter = seconds }

    /// Show a passive toast (the variant colors the icon/badge). Mutates the view hierarchy,
    /// so it hops to the main thread when a caller surfaces a notice from a background queue.
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

    /// Take `toast` down after `dismissAfter`. The deadline is read now, so a later
    /// `reapplyDuration` moves the next toast rather than one already counting down.
    private func armAutoDismiss(_ toast: ToastView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter) { [weak self, weak toast] in
            guard let toast else { return }
            self?.dismiss(toast)
        }
    }

    /// A non-modal actionable toast: it answers only through its buttons (the body isn't
    /// clickable) and — unlike `confirm` — neither gates keyboard focus nor claims Return / Esc,
    /// so it never steals input from the terminal. `autoDismiss` arms the same timer `show()` uses;
    /// without it the card persists until something dismisses it. Returns the view so the caller
    /// can dismiss it when the notice stops being relevant. Call on the main thread.
    @discardableResult
    func showSticky(
        _ content: ToastContent, actions: [ToastAction], showsClose: Bool = false,
        autoDismiss: Bool = false
    ) -> ToastView {
        dispatchPrecondition(condition: .onQueue(.main))  // fail fast on an accidental off-main call
        let toast = ToastView(
            content: content, actions: actions, armsKeys: false, showsClose: showsClose)
        stack.addArrangedSubview(toast)
        toast.animateIn()
        if autoDismiss { armAutoDismiss(toast) }
        return toast
    }

    /// Present a sticky, actionable confirm toast (no auto-dismiss). Returns the view so the
    /// caller can gate focus, wire its "×" to cancel, and dismiss it on answer.
    @discardableResult
    func confirm(_ content: ToastContent, actions: [ToastAction]) -> ToastView {
        let toast = ToastView(content: content, actions: actions)
        stack.addArrangedSubview(toast)
        toast.animateIn()
        return toast
    }

    /// Present a caller-built card in the stack (no auto-dismiss, no built-in close affordance). The
    /// caller owns its content and lifetime; used by the app-global update card, which morphs in
    /// place across states and is torn down via `remove(_:)` when the flow ends.
    func present(card: ShadowCardView) {
        dispatchPrecondition(condition: .onQueue(.main))
        stack.addArrangedSubview(card)
        card.superview?.layoutSubtreeIfNeeded()  // resolve the frame before scaling about its center
        Motion.springScaleFade(card, appearing: true)
    }

    /// Spring a caller-built card back out and remove it. Pairs with `present(card:)`.
    func remove(card: ShadowCardView) {
        dispatchPrecondition(condition: .onQueue(.main))
        Motion.springScaleFade(card, appearing: false) { [weak self, weak card] in
            guard let self, let card else { return }
            self.stack.removeArrangedSubview(card)
            card.removeFromSuperview()
        }
    }

    /// The toasts a dismiss chord can take down, oldest (topmost) first. Excludes the caller-owned
    /// cards that share the stack (the update card, the font-size card) and anything already
    /// springing out.
    private var dismissible: [ToastView] {
        stack.arrangedSubviews.compactMap { $0 as? ToastView }.filter { !$0.isDismissing }
    }

    /// Dismiss the oldest toast, answering it the way its own Dismiss button would. Returns whether
    /// there was one, so repeated calls walk down the stack and the last is a no-op.
    @discardableResult
    func dismissOldest() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let toast = dismissible.first else { return false }
        answerCancel(toast)
        return true
    }

    /// Clear every dismissible toast, each answered the way its own Dismiss button would.
    func dismissAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        dismissible.forEach(answerCancel)
    }

    /// Run the card's cancel action when it has one, else just take it down. Routing through the
    /// action matters: an attention card's Dismiss also clears the tab's colored number, so
    /// removing the view alone would leave the tab flagged with nothing on screen explaining it.
    private func answerCancel(_ toast: ToastView) {
        guard let cancel = toast.cancelAction else {
            dismiss(toast)
            return
        }
        cancel()
    }

    /// Dismiss a toast now (spring out + remove). Idempotent.
    func dismiss(_ toast: ToastView) {
        // `animateOut` is idempotent, so a click + the auto-dismiss timer can't double-remove.
        toast.animateOut { [weak self, weak toast] in
            guard let self, let toast else { return }
            self.removeCollapsing(toast)
        }
    }

    /// Take `toast` out of the stack and let whatever sat below it slide up into the gap.
    ///
    /// The card springs out on its own, but its slot is only freed when it leaves the stack, so a
    /// plain removal snapped every card below straight to its new frame. Removing inside an implicit
    /// animation group and forcing the layout there is what turns that snap into a slide. Reduce
    /// motion takes the old path, unanimated, per the app's motion policy.
    private func removeCollapsing(_ toast: ToastView) {
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
            stack.layoutSubtreeIfNeeded()  // inside the group, so the survivors animate to their new frames
        }
    }
}
