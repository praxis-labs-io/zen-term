import AppKit
import PaneKit

/// Recursively lays out a PaneNode: a leaf hosts its provided view; a split places
/// two child containers along its axis at the fixed ratio with a gutter gap.
final class SplitContainerView: NSView {
    init(node: PaneNode, gutter: CGFloat = 12, leafView: (PaneID) -> NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(node, gutter: gutter, leafView: leafView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build(_ node: PaneNode, gutter: CGFloat, leafView: (PaneID) -> NSView) {
        switch node {
        case let .leaf(id):
            let v = leafView(id)
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor),
                v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor),
                v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

        case let .split(_, axis, ratio, a, b):
            let first = SplitContainerView(node: a, gutter: gutter, leafView: leafView)
            let second = SplitContainerView(node: b, gutter: gutter, leafView: leafView)
            addSubview(first)
            addSubview(second)

            // Common cross-axis pinning + gutter along the split axis, with `first`
            // sized to `ratio` of the available space (minus half the gutter).
            if axis == .vertical {
                NSLayoutConstraint.activate([
                    first.leadingAnchor.constraint(equalTo: leadingAnchor),
                    first.topAnchor.constraint(equalTo: topAnchor),
                    first.bottomAnchor.constraint(equalTo: bottomAnchor),
                    second.trailingAnchor.constraint(equalTo: trailingAnchor),
                    second.topAnchor.constraint(equalTo: topAnchor),
                    second.bottomAnchor.constraint(equalTo: bottomAnchor),
                    second.leadingAnchor.constraint(equalTo: first.trailingAnchor, constant: gutter),
                    first.widthAnchor.constraint(equalTo: widthAnchor, multiplier: ratio, constant: -gutter / 2),
                ])
            } else {
                NSLayoutConstraint.activate([
                    first.leadingAnchor.constraint(equalTo: leadingAnchor),
                    first.trailingAnchor.constraint(equalTo: trailingAnchor),
                    first.topAnchor.constraint(equalTo: topAnchor),
                    second.leadingAnchor.constraint(equalTo: leadingAnchor),
                    second.trailingAnchor.constraint(equalTo: trailingAnchor),
                    second.bottomAnchor.constraint(equalTo: bottomAnchor),
                    second.topAnchor.constraint(equalTo: first.bottomAnchor, constant: gutter),
                    first.heightAnchor.constraint(equalTo: heightAnchor, multiplier: ratio, constant: -gutter / 2),
                ])
            }
        }
    }
}
