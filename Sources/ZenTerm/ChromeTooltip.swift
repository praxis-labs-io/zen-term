import AppKit

/// A small branded hover tooltip: the chrome's card idiom (themed background + hairline edge +
/// a soft elevation shadow) holding a muted label and, when known, the action's live keybind
/// chip. Replaces the native `NSView.toolTip`, which is OS-drawn — unbranded, not centered on the
/// trigger, and unaware of the window. Positioned by `TooltipPresenter`.
final class ChromeTooltip: ShadowCardView {
    init(label: String, shortcut: String?) {
        super.init(frame: .zero)
        // Framed directly by `TooltipPresenter` (not Auto Layout), so leave the default
        // translatesAutoresizingMaskIntoConstraints = true.
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = FloatShadow.edge.cgColor
        // A lighter elevation than FloatShadow's full card shadow — a tooltip floats just above its
        // trigger, not over the whole canvas. Black is a theme-independent shadow (the documented
        // FloatShadow exception), not a chrome color. Via `NSView.shadow`, not `layer.shadow*`,
        // so AppKit's view→layer re-sync can't zero it (see FloatShadow.applyShadow).
        layer?.masksToBounds = false
        let elevation = NSShadow()
        elevation.shadowColor = NSColor.black.withAlphaComponent(0.35)
        elevation.shadowBlurRadius = 8
        elevation.shadowOffset = NSSize(width: 0, height: -3)
        shadow = elevation

        let text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: 11, weight: .medium)
        text.textColor = Theme.current.chrome.ink(alpha: 0.9)

        var views: [NSView] = [text]
        if let shortcut, !shortcut.isEmpty {
            views.append(KeycapView(shortcut: shortcut, showsBackground: true))
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Never intercept the pointer — the tooltip is a passive label floating above the trigger.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
