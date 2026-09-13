import AppKit

final class ChromePopover: NSView {
    private let makeContent: () -> NSView
    private var content: NSView?
    private var backdrop: BackdropView?

    init(makeContent: @escaping () -> NSView) {
        self.makeContent = makeContent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false
        applyShadow()
        applyThemeColors()
        installContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var isShown: Bool { superview != nil }

    func toggle(in host: NSView, above anchor: NSView) {
        isShown ? hide() : show(in: host, above: anchor)
    }

    func show(in host: NSView, above anchor: NSView, trailingInset: CGFloat = 12, gap: CGFloat = 8) {
        guard superview == nil else { return }
        let backdrop = BackdropView { [weak self] in self?.hide() }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: host.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        self.backdrop = backdrop

        layer?.opacity = 0
        host.addSubview(self)
        NSLayoutConstraint.activate([
            trailingAnchor.constraint(equalTo: anchor.trailingAnchor, constant: -trailingInset),
            bottomAnchor.constraint(equalTo: anchor.topAnchor, constant: -gap),
            leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 12),
            topAnchor.constraint(greaterThanOrEqualTo: host.topAnchor, constant: 12),
        ])
        Motion.fade(self, to: 1)
    }

    func hide() {
        backdrop?.removeFromSuperview()
        backdrop = nil
        removeFromSuperview()
    }

    /// Swallows clicks so they don't reach the dismissing backdrop.
    override func mouseDown(with event: NSEvent) {}

    func reapplyTheme() {
        applyThemeColors()
        installContent()
    }

    private func installContent() {
        content?.removeFromSuperview()
        let view = makeContent()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        content = view
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            view.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    private func applyThemeColors() {
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = FloatShadow.edge.cgColor
    }

    /// Theme-independent black, set via `NSView.shadow` for the same reason as `FloatShadow`.
    private func applyShadow() {
        layer?.masksToBounds = false
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        self.shadow = shadow
    }
}
