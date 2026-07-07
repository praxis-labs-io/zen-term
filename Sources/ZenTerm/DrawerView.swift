import AppKit

enum DrawerEdge { case bottom, right }

/// A fixed-size container docking one terminal surface at the tab region's bottom or
/// right edge, with a subtle divider line on the inner edge and padding matching the
/// panes. The hosted surface view fills the padded area.
final class DrawerView: NSView {
    static let bottomHeight: CGFloat = 240
    static let rightWidth: CGFloat = 360

    private static let divider = NSColor(white: 1, alpha: 0.08)

    init(edge: DrawerEdge, content: NSView, background: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = background.cgColor

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Self.divider.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let pad: CGFloat = 10
        var cs: [NSLayoutConstraint] = [
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            content.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
        ]
        switch edge {
        case .bottom:
            cs += [
                heightAnchor.constraint(equalToConstant: Self.bottomHeight),
                line.topAnchor.constraint(equalTo: topAnchor),
                line.leadingAnchor.constraint(equalTo: leadingAnchor),
                line.trailingAnchor.constraint(equalTo: trailingAnchor),
                line.heightAnchor.constraint(equalToConstant: 1),
            ]
        case .right:
            cs += [
                widthAnchor.constraint(equalToConstant: Self.rightWidth),
                line.leadingAnchor.constraint(equalTo: leadingAnchor),
                line.topAnchor.constraint(equalTo: topAnchor),
                line.bottomAnchor.constraint(equalTo: bottomAnchor),
                line.widthAnchor.constraint(equalToConstant: 1),
            ]
        }
        NSLayoutConstraint.activate(cs)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
