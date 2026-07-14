import AppKit
import PaneKit

/// Recursively lays out a PaneNode: a leaf hosts its provided view; a split places
/// two child containers along its axis at the fixed ratio with a gutter gap.
final class SplitContainerView: NSView {
    /// The constraint carrying this split's ratio (nil on a leaf container). A multiplier
    /// constraint is immutable, so `setRatio` swaps it for a fresh one instead of mutating.
    private var ratioConstraint: NSLayoutConstraint?
    private var firstChild: NSView?
    private var secondChild: NSView?
    /// The along-axis link pinning `second` a gutter past `first` (`second.leading == first.trailing`
    /// / `second.top == first.bottom`). Held so `animateSplitIn` can detach it while the new pane
    /// slides in at a fixed size, then restore it.
    private var secondFollowsFirst: NSLayoutConstraint?
    private var splitAxis: SplitAxis?
    private var gutter: CGFloat = 0
    /// True while `animateSplitIn` owns `first`'s sizing via the temp extents below; a `setRatio`
    /// resize finalizes it first so the fixed-extent and ratio constraints can't both be required.
    private var isAnimatingIn = false
    private var splitInExtents: [NSLayoutConstraint] = []

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
        // A split-in push has `first` pinned to a fixed extent for the slide; finalize it first so the
        // resize doesn't add a second, conflicting required width — and so the resize still lands.
        settleSplitIn()
        guard let firstChild, let splitAxis, let old = ratioConstraint else { return }
        old.isActive = false
        let next = makeRatioConstraint(ratio, first: firstChild, axis: splitAxis)
        next.isActive = true
        ratioConstraint = next
    }

    /// Finish an in-flight `animateSplitIn` immediately (or from its own completion): drop the temp
    /// extents, stop the slide, unclip, and — unless a rebuild reparented the children into a fresh
    /// container — restore the canonical ratio constraints. Idempotent.
    private func settleSplitIn() {
        guard isAnimatingIn else { return }
        isAnimatingIn = false
        // Release the temp extents unconditionally — they're attached to the child views, so leaving
        // them active after a reparent would wrongly constrain the children in their new container.
        splitInExtents.forEach { $0.isActive = false }
        splitInExtents = []
        secondChild?.layer?.removeAnimation(forKey: "split.slide")
        secondChild?.layer?.transform = CATransform3DIdentity
        SlideClip.remove(from: self)
        guard let first = firstChild, let second = secondChild,
            first.superview === self, second.superview === self
        else { return }
        ratioConstraint?.isActive = true
        secondFollowsFirst?.isActive = true
    }

    /// Animate this freshly-built split in like a drawer push: the pre-existing child (`first`)
    /// compresses from filling the container to its ratio — a real resize, so its terminal reflows —
    /// while the new child (`second`, always the just-added pane) slides in at its final size from the
    /// trailing (vertical split) or bottom (horizontal split) edge. The two stay one gutter apart the
    /// whole way, mirroring the drawer push. `content` is clipped for the duration so the parked new
    /// pane doesn't spill into siblings; on completion the canonical ratio constraints are restored
    /// (same size, no jump). The caller guards Reduce Motion. Must be called once the split is laid
    /// out at its final ratio (so the final child sizes are known).
    func animateSplitIn(duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        guard let first = firstChild, let second = secondChild, let axis = splitAxis,
            let ratioConstraint, let secondFollowsFirst
        else { return }
        let vertical = axis == .vertical
        let extent = vertical ? bounds.width : bounds.height
        guard extent > 1 else { return }
        isAnimatingIn = true

        // Read the final child sizes from the canonical (ratio) layout before swapping it out.
        let finalFirst = vertical ? first.bounds.width : first.bounds.height
        let finalSecond = vertical ? second.bounds.width : second.bounds.height
        let slide = finalSecond + gutter

        // Detach the two children's sizing: `first` gets an animatable extent (full → final); `second`
        // a fixed final extent it slides into from the outer edge (no grow-from-zero reflow jitter).
        ratioConstraint.isActive = false
        secondFollowsFirst.isActive = false
        let firstExtent = (vertical ? first.widthAnchor : first.heightAnchor).constraint(equalToConstant: extent)
        let secondExtent = (vertical ? second.widthAnchor : second.heightAnchor).constraint(
            equalToConstant: finalSecond)
        firstExtent.isActive = true
        secondExtent.isActive = true
        splitInExtents = [firstExtent, secondExtent]
        layoutSubtreeIfNeeded()  // first fills; second sits at final size against the trailing/bottom edge

        // Park `second` just past that edge and clip, so it doesn't spill into siblings as it slides
        // (the expanded clip spares the freshly-focused pane's halo — see SlideClip).
        SlideClip.apply(to: self)
        second.wantsLayer = true
        let keyPath = vertical ? "transform.translation.x" : "transform.translation.y"
        let from: CGFloat = vertical ? slide : -slide  // right for a vertical split, down for horizontal
        second.layer?.transform = CATransform3DIdentity  // model rests in place
        let slideAnim = CABasicAnimation(keyPath: keyPath)
        slideAnim.fromValue = from
        slideAnim.toValue = 0
        slideAnim.duration = duration
        slideAnim.timingFunction = timing

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            firstExtent.animator().constant = finalFirst
            second.layer?.add(slideAnim, forKey: "split.slide")
        } completionHandler: { [weak self] in
            self?.settleSplitIn()
        }
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
            secondChild = second
            splitAxis = axis
            self.gutter = gutter
            let ratioConstraint = makeRatioConstraint(ratio, first: first, axis: axis)
            self.ratioConstraint = ratioConstraint

            // Common cross-axis pinning + gutter along the split axis, with `first`
            // sized to `ratio` of the available space (minus half the gutter).
            let follows =
                axis == .vertical
                ? second.leadingAnchor.constraint(equalTo: first.trailingAnchor, constant: gutter)
                : second.topAnchor.constraint(equalTo: first.bottomAnchor, constant: gutter)
            secondFollowsFirst = follows
            if axis == .vertical {
                NSLayoutConstraint.activate([
                    first.leadingAnchor.constraint(equalTo: leadingAnchor),
                    first.topAnchor.constraint(equalTo: topAnchor),
                    first.bottomAnchor.constraint(equalTo: bottomAnchor),
                    second.trailingAnchor.constraint(equalTo: trailingAnchor),
                    second.topAnchor.constraint(equalTo: topAnchor),
                    second.bottomAnchor.constraint(equalTo: bottomAnchor),
                    follows,
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
                    follows,
                    ratioConstraint,
                ])
            }
        }
    }
}
