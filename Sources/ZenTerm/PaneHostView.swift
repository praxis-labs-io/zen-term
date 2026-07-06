import AppKit

/// The single floating pane: canvas background, a rounded + bordered pane inset by
/// the gutter, hosting `content`. This is the one-pane seed of the split canvas
/// that Epic 1 generalizes; the dynamic focus halo is deferred to Epic 1.
final class PaneHostView: NSView {
    private let gutter: CGFloat = 12

    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0x23 / 255.0, green: 0x21 / 255.0, blue: 0x36 / 255.0, alpha: 1).cgColor

        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.cornerRadius = 12
        pane.layer?.masksToBounds = true          // clip terminal content to rounded corners
        pane.layer?.borderWidth = 1
        pane.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        pane.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pane)

        content.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(content)

        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            pane.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            pane.topAnchor.constraint(equalTo: topAnchor, constant: gutter),
            pane.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -gutter),

            content.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            content.topAnchor.constraint(equalTo: pane.topAnchor),
            content.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
