import AppKit

/// A small branded hover tooltip: the shared hover-card idiom holding a muted label and, when
/// known, the action's live keybind chip. Replaces the native `NSView.toolTip`, which is OS-drawn
/// — unbranded, not centered on the trigger, and unaware of the window. Positioned by
/// `TooltipPresenter`.
final class ChromeTooltip: HoverCardView {
    init(label: String, shortcut: String?) {
        super.init(frame: .zero)
        var views: [NSView] = [Self.makeLabel(label)]
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
}
