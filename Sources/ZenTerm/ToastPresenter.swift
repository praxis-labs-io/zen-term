import AppKit

/// Presents transient toasts stacked in the top-right of a host view. Each springs in,
/// auto-dismisses after a delay (or on click), and springs out. Window-level and content-
/// agnostic, so anything that needs to surface a brief notice can reuse it.
final class ToastPresenter {
    /// Rosé Pine Moon gold — the default icon tint for an advisory/warning toast.
    static let warning = NSColor(srgbRed: 0xf6 / 255, green: 0xc1 / 255, blue: 0x77 / 255, alpha: 1)

    private let stack = NSStackView()
    private let dismissAfter: TimeInterval

    init(host: NSView, topInset: CGFloat, trailingInset: CGFloat, dismissAfter: TimeInterval = 4) {
        self.dismissAfter = dismissAfter
        stack.orientation = .vertical
        stack.alignment = .trailing  // new toasts stack downward, right-aligned
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)  // added last → above the mounted canvas
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: topInset),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -trailingInset),
        ])
    }

    /// Show a toast; `tint` colors the icon. Mutates the view hierarchy, so it hops to the
    /// main thread when a caller surfaces a notice from a background queue.
    func show(_ content: ToastContent, tint: NSColor = ToastPresenter.warning) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.show(content, tint: tint) }
            return
        }
        let toast = ToastView(content: content, tint: tint)
        toast.onClick = { [weak self, weak toast] in
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

    private func dismiss(_ toast: ToastView) {
        // `animateOut` is idempotent, so a click + the auto-dismiss timer can't double-remove.
        toast.animateOut { [weak self, weak toast] in
            guard let self, let toast else { return }
            self.stack.removeArrangedSubview(toast)
            toast.removeFromSuperview()
        }
    }
}
