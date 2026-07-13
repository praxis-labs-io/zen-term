import AppKit
import PaneKit

/// Recursively lays out a PaneNode: a leaf hosts its provided view; a split places
/// two child containers along its axis at the fixed ratio with a gutter gap.
final class SplitContainerView: NSView {
    /// The constraint carrying this split's ratio (nil on a leaf container). A multiplier
    /// constraint is immutable, so `setRatio` swaps it for a fresh one instead of mutating.
    private var ratioConstraint: NSLayoutConstraint?
    private var firstChild: NSView?
    private var splitAxis: SplitAxis?
    private var gutter: CGFloat = 0

    /// Called for every split node as its container is built, with the split's id and its
    /// container view. Lets the pane controller clamp resizes to a pixel min instead of a
    /// bare ratio, and retarget the ratio in place via `setRatio`.
    init(
        node: PaneNode, gutter: CGFloat = ChromeMetrics.panelGap,
        register: ((SplitID, SplitContainerView) -> Void)? = nil, leafView: (PaneID) -> NSView
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(node, gutter: gutter, register: register, leafView: leafView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Re-point this split at a new ratio without rebuilding any views — the ⌥-arrow resize
    /// path, hot under key repeat. Only the one constraint is swapped; layout flows on the
    /// next pass.
    func setRatio(_ ratio: Double) {
        guard let firstChild, let splitAxis, let old = ratioConstraint else { return }
        old.isActive = false
        let next = makeRatioConstraint(ratio, first: firstChild, axis: splitAxis)
        next.isActive = true
        ratioConstraint = next
    }

    /// The one ratio formula, shared by `build` and `setRatio` so the two paths can't drift:
    /// `first` sized to `ratio` of the container along the axis, minus its half of the gutter.
    private func makeRatioConstraint(_ ratio: Double, first: NSView, axis: SplitAxis) -> NSLayoutConstraint {
        axis == .vertical
            ? first.widthAnchor.constraint(
                equalTo: widthAnchor, multiplier: ratio, constant: -gutter / 2)
            : first.heightAnchor.constraint(
                equalTo: heightAnchor, multiplier: ratio, constant: -gutter / 2)
    }

    private func build(
        _ node: PaneNode, gutter: CGFloat,
        register: ((SplitID, SplitContainerView) -> Void)?, leafView: (PaneID) -> NSView
    ) {
        switch node {
        case .leaf(let id):
            let v = leafView(id)
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor),
                v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor),
                v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

        case .split(let id, let axis, let ratio, let a, let b):
            register?(id, self)  // `self` is this split's container; its axis-extent is the split size
            let first = SplitContainerView(node: a, gutter: gutter, register: register, leafView: leafView)
            let second = SplitContainerView(node: b, gutter: gutter, register: register, leafView: leafView)
            addSubview(first)
            addSubview(second)
            firstChild = first
            splitAxis = axis
            self.gutter = gutter
            let ratioConstraint = makeRatioConstraint(ratio, first: first, axis: axis)
            self.ratioConstraint = ratioConstraint

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
                    ratioConstraint,
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
                    ratioConstraint,
                ])
            }
        }
    }
}
