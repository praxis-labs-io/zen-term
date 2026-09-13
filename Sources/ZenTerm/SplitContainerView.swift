import AppKit
import PaneKit

final class SplitContainerView: NSView {
    // A multiplier is immutable, so `setRatio` swaps the constraint.
    private var ratioConstraint: NSLayoutConstraint?
    private var firstChild: NSView?
    private var secondChild: NSView?
    private var secondFollowsFirst: NSLayoutConstraint?
    private var splitAxis: SplitAxis?
    private var gutter: CGFloat = 0
    private var isAnimatingIn = false
    private var splitInExtents: [NSLayoutConstraint] = []
    private var suspendGrids: ((Bool) -> Void)?

    init(
        node: PaneNode, gutter: CGFloat = ChromeMetrics.panelGap,
        register: ((SplitID, SplitContainerView) -> Void)? = nil, leafView: (PaneID) -> NSView
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(node, gutter: gutter, register: register, leafView: leafView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setGutter(_ next: CGFloat) {
        guard gutter != next else { return }
        gutter = next
        secondFollowsFirst?.constant = next
        ratioConstraint?.constant = -next / 2
    }

    func setRatio(_ ratio: Double) {
        settleSplitIn()
        guard let firstChild, let splitAxis, let old = ratioConstraint else { return }
        old.isActive = false
        let next = makeRatioConstraint(ratio, first: firstChild, axis: splitAxis)
        next.isActive = true
        ratioConstraint = next
    }

    private func settleSplitIn() {
        guard isAnimatingIn else { return }
        isAnimatingIn = false
        defer {
            suspendGrids?(false)
            suspendGrids = nil
        }
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

    func animateSplitIn(
        duration: CFTimeInterval, timing: CAMediaTimingFunction,
        suspendGrids: @escaping (Bool) -> Void = { _ in }
    ) {
        guard let first = firstChild, let second = secondChild, let axis = splitAxis,
            let ratioConstraint, let secondFollowsFirst
        else { return }
        let vertical = axis == .vertical
        let extent = vertical ? bounds.width : bounds.height
        guard extent > 1 else { return }
        isAnimatingIn = true
        suspendGrids(true)
        self.suspendGrids = suspendGrids

        let finalFirst = vertical ? first.bounds.width : first.bounds.height
        let finalSecond = vertical ? second.bounds.width : second.bounds.height
        let slide = finalSecond + gutter

        ratioConstraint.isActive = false
        secondFollowsFirst.isActive = false
        let firstExtent = (vertical ? first.widthAnchor : first.heightAnchor).constraint(equalToConstant: extent)
        let secondExtent = (vertical ? second.widthAnchor : second.heightAnchor).constraint(
            equalToConstant: finalSecond)
        firstExtent.isActive = true
        secondExtent.isActive = true
        splitInExtents = [firstExtent, secondExtent]
        layoutSubtreeIfNeeded()

        SlideClip.apply(to: self)
        second.wantsLayer = true
        let keyPath = vertical ? "transform.translation.x" : "transform.translation.y"
        let from: CGFloat = vertical ? slide : -slide
        second.layer?.transform = CATransform3DIdentity
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

    // A rebuild can free this view before its animation completion runs, which would strand its grids frozen.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { settleSplitIn() }
    }

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
            register?(id, self)
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
