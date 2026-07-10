import AppKit
import TabKit

/// The agent activity a tab's number signals: `idle` is the default muted color; `waiting`
/// (an agent needs feedback/permission) is rose.
enum TabAgentState {
    case idle, waiting
}

struct TabBarItem {
    let id: TabID
    let index: Int  // 1-based number shown before the title
    let title: String
    let isActive: Bool
    let agentState: TabAgentState
}

/// The bottom-left numbered tab bar. Stateless beyond its last rendered snapshot;
/// selection/close/new all flow out through callbacks. Clicking a tab selects it;
/// middle-clicking a tab closes it; the trailing "+" chip makes a new tab. The
/// active tab is marked with an iris underline; the rounded box is a hover-only
/// affordance shared by tabs and the "+".
final class TabBarView: NSView {
    private let onSelect: (TabID) -> Void
    private let onClose: (TabID) -> Void
    private let onNewTab: () -> Void

    static let height: CGFloat = 30

    fileprivate static let activeInk = Theme.current.chrome.ink(0.95, alpha: 1)
    fileprivate static let idleInk = Theme.current.chrome.ink(0.92, alpha: 0.55)
    fileprivate static let numberInk = Theme.current.chrome.ink(0.92, alpha: 0.35)

    private let stack = NSStackView()
    /// A single iris underline that slides along the bar to the active tab (a tracer),
    /// rather than a per-chip underline snapping on/off.
    /// Owned (not an NSView backing layer) so its anchor point is ours: a left-edge anchor
    /// lets us keyframe the left edge and width directly, for a stretch that only reaches
    /// toward the target rather than growing symmetrically about the center.
    private let tracer = CALayer()
    private var activeTabID: TabID?
    /// How long the tracer takes to reach the newly-selected tab — matched to the canvas
    /// page-slide (0.28s) so the two land together.
    private static let tracerDuration: CFTimeInterval = 0.28

    init(
        onSelect: @escaping (TabID) -> Void,
        onClose: @escaping (TabID) -> Void,
        onNewTab: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onClose = onClose
        self.onNewTab = onNewTab
        super.init(frame: .zero)
        wantsLayer = true
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        tracer.backgroundColor = Theme.current.chrome.accent.nsColor.cgColor
        tracer.cornerRadius = 1
        tracer.anchorPoint = CGPoint(x: 0, y: 0.5)  // position.x is the left edge
        tracer.zPosition = 1  // above the chips regardless of sublayer order
        tracer.isHidden = true  // placed under the active chip on the first render
        layer?.addSublayer(tracer)
        // Nudge up by half the pane canvas's 12pt bottom gutter so the chips read as
        // centered in the whole band between the terminal content and the window edge,
        // not just within this bar's own height. (This view's superview is flipped, so
        // a negative centerY constant moves the stack visually up.)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(_ items: [TabBarItem]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var activeChip: Chip?
        for item in items {
            let id = item.id
            let chip = Chip(
                attributed: Self.tabLabel(item),
                onClick: { [weak self] in self?.onSelect(id) },
                onMiddleClick: { [weak self] in self?.onClose(id) })
            stack.addArrangedSubview(chip)
            if item.isActive { activeChip = chip }
        }
        let plus = IconButton(
            symbol: "plus", size: NSSize(width: 22, height: 22),
            pointSize: 11, accessibilityLabel: "New tab",
            onClick: { [weak self] in self?.onNewTab() })
        stack.addArrangedSubview(plus)

        // Slide the tracer to the active tab. Animate only when the active tab actually
        // changed (not on the first render, nor a re-render of the same selection).
        let newActive = items.first(where: \.isActive)?.id
        layoutSubtreeIfNeeded()  // resolve chip frames before measuring the underline
        if let activeChip {
            let shouldAnimate = activeTabID != nil && activeTabID != newActive
            moveTracer(to: tracerFrame(for: activeChip), animated: shouldAnimate)
            tracer.isHidden = false
        } else {
            tracer.isHidden = true
        }
        activeTabID = newActive
    }

    /// The 2pt underline frame under `chip`, spanning its label (inset 9pt each side),
    /// in this view's coordinates.
    private func tracerFrame(for chip: NSView) -> CGRect {
        let f = chip.convert(chip.bounds, to: self)
        return CGRect(x: f.minX + 9, y: f.minY, width: f.width - 18, height: 2)
    }

    /// Set the tracer's frame with no implicit animation (an owned layer would otherwise
    /// animate every property change on its own default 0.25s curve).
    private func setTracerFrame(_ frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tracer.frame = frame
        CATransaction.commit()
    }

    private func moveTracer(to target: CGRect, animated: Bool) {
        guard animated, !Motion.isReduceMotionEnabled() else {
            setTracerFrame(target)
            return
        }
        let start = tracer.presentation()?.frame ?? tracer.frame  // live frame, mid-slide if interrupted
        setTracerFrame(target)  // model = final resting frame

        // The stretch, expressed as the left edge (position.x, since the anchor's x is 0)
        // and the width: the leading edge reaches the target while the trailing edge holds,
        // then the trailing edge eases in and the width closes — so it only reaches toward
        // the target, never growing symmetrically about the center.
        let movingRight = target.midX >= start.midX
        let leftValues: [CGFloat] =
            movingRight
            ? [start.minX, start.minX, target.minX] : [start.minX, target.minX, target.minX]
        let widthValues: [CGFloat] =
            movingRight
            ? [start.width, target.maxX - start.minX, target.width]
            : [start.width, start.maxX - target.minX, target.width]

        let left = CAKeyframeAnimation(keyPath: "position.x")
        left.values = leftValues.map { $0 as NSNumber }
        let width = CAKeyframeAnimation(keyPath: "bounds.size.width")
        width.values = widthValues.map { $0 as NSNumber }
        for anim in [left, width] {
            anim.keyTimes = [0, 0.5, 1]
            anim.duration = Self.tracerDuration
            anim.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),  // leading edge darts toward the target
                CAMediaTimingFunction(name: .easeInEaseOut),  // trailing edge eases in
            ]
        }
        tracer.add(left, forKey: "tracer.left")
        tracer.add(width, forKey: "tracer.width")
    }

    private static func tabLabel(_ item: TabBarItem) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let ink = item.isActive ? activeInk : idleInk
        let numberColor: NSColor
        switch item.agentState {
        case .idle: numberColor = numberInk
        case .waiting: numberColor = Theme.current.chrome.attention.nsColor
        }
        let s = NSMutableAttributedString(
            string: "\(item.index) ",
            attributes: [.font: font, .foregroundColor: numberColor])
        s.append(
            NSAttributedString(
                string: item.title,
                attributes: [.font: font, .foregroundColor: ink, .kern: 0.4]))
        return s
    }

    /// A rounded box holding a centered label. The box background appears on hover
    /// only; the active tab is marked by the shared tracer underline. Used for both tabs
    /// and the "+" affordance so they share hover feel and stay vertically aligned.
    private final class Chip: NSView {
        private let onClick: () -> Void
        private let onMiddleClick: (() -> Void)?
        private var isHovered = false

        init(
            attributed: NSAttributedString,
            onClick: @escaping () -> Void, onMiddleClick: (() -> Void)?
        ) {
            self.onClick = onClick
            self.onMiddleClick = onMiddleClick
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 6

            let label = NSTextField(labelWithAttributedString: attributed)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                heightAnchor.constraint(equalToConstant: 22),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                    owner: self))
        }

        override func mouseEntered(with event: NSEvent) { isHovered = true; updateBackground() }
        override func mouseExited(with event: NSEvent) { isHovered = false; updateBackground() }
        override func mouseDown(with event: NSEvent) { onClick() }
        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 { onMiddleClick?() }  // middle-click closes
        }

        private func updateBackground() {
            guard let layer else { return }
            Motion.ease(
                layer, keyPath: "backgroundColor",
                to: (isHovered ? Theme.current.chrome.ink(1, alpha: 0.08) : .clear).cgColor)
        }
    }
}
