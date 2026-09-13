import AppKit

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
