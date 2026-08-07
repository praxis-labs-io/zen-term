import AppKit

/// Presents transient toasts stacked in the top-right of a host view. Each springs in,
/// auto-dismisses after a delay (or on click), and springs out. Window-level and content-
/// agnostic, so anything that needs to surface a brief notice can reuse it.
final class ToastPresenter {
    private let stack = NSStackView()
    private let dismissAfter: TimeInterval
    /// The two insets, held so a `window-gutter` / `window-chrome` change can re-point them. The
    /// presenter is built lazily on the first toast, so without this the stack keeps whatever the
    /// metrics were at that moment for the life of the window.
    private let topConstraint: NSLayoutConstraint
    private let trailingConstraint: NSLayoutConstraint

    init(host: NSView, topInset: CGFloat, trailingInset: CGFloat, dismissAfter: TimeInterval = 4) {
        self.dismissAfter = dismissAfter
        stack.orientation = .vertical
        stack.alignment = .trailing  // new toasts stack downward, right-aligned
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)  // added last → above the mounted canvas
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
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter) { [weak self, weak toast] in
            guard let toast else { return }
            self?.dismiss(toast)
        }
    }

    /// A sticky, non-modal actionable toast: it persists (no auto-dismiss), answers only
    /// through its buttons (the body isn't clickable), and — unlike `confirm` — neither gates
    /// keyboard focus nor arms its buttons' Return / Esc key equivalents, so it never steals
    /// input from the terminal. Returns the view so the caller can dismiss it when the notice
    /// stops being relevant. Call on the main thread.
    @discardableResult
    func showSticky(_ content: ToastContent, actions: [ToastAction]) -> ToastView {
        dispatchPrecondition(condition: .onQueue(.main))  // fail fast on an accidental off-main call
        let toast = ToastView(content: content, actions: actions, keyEquivalents: false)
        stack.addArrangedSubview(toast)
        toast.animateIn()
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
