import AppKit

/// A small rotating arc for a step whose length nothing knows. `NSProgressIndicator` tints from
/// `effectiveAppearance`, which the chrome bans, so this is an accent arc on a neutral ring,
/// mirroring what `UpdateProgressBar` does for the same reason.
///
/// Under Reduce Motion it holds still as a ring: a stopped spinner reads as a hung app.
final class Spinner: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private static let diameter: CGFloat = 13
    private static let lineWidth: CGFloat = 2
    private static let rotationKey = "zenterm.spin"

    /// Whether the arc is turning. Setting it re-adds or removes the rotation, so a card that
    /// finishes and comes back does not stack two animations.
    var isSpinning = false {
        didSet {
            guard isSpinning != oldValue else { return }
            applySpin()
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        for shape in [track, arc] {
            shape.fillColor = nil
            shape.lineWidth = Self.lineWidth
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.diameter, height: Self.diameter)
    }

    /// The arc rotates about the view's center, so both shapes are sized and centered here rather
    /// than pinned by constraints: a layer has no autolayout of its own.
    override func layout() {
        super.layout()
        let inset = Self.lineWidth / 2
        let box = bounds.insetBy(dx: inset, dy: inset)
        let ring = CGPath(ellipseIn: box, transform: nil)
        track.path = ring
        track.frame = bounds
        arc.path = ring
        arc.frame = bounds
        // Three quarters of the ring, so the gap is what reads as turning.
        arc.strokeEnd = 0.75
        applySpin()
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        track.strokeColor = chrome.fill(alpha: ChromeTheme.border).cgColor
        arc.strokeColor = chrome.accent.nsColor.cgColor
    }

    private func applySpin() {
        arc.removeAnimation(forKey: Self.rotationKey)
        guard isSpinning, !Motion.isReduceMotionEnabled() else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -CGFloat.pi * 2
        spin.duration = 0.9
        spin.repeatCount = .infinity
        arc.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        arc.frame = bounds
        arc.add(spin, forKey: Self.rotationKey)
    }
}
