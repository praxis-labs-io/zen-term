import AppKit

/// Not `NSProgressIndicator`, which tints from `effectiveAppearance` rather than the theme.
final class UpdateProgressBar: NSView {
    private let fill = CALayer()
    private static let height: CGFloat = 4
    private static let sweepFraction: CGFloat = 0.3
    private static let sweepDuration: CFTimeInterval = 0.9

    var fraction: Double? {
        didSet {
            guard fraction != oldValue else { return }
            apply()
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.capsule(Self.height)
        layer?.masksToBounds = true
        fill.cornerRadius = ChromeMetrics.Radius.capsule(Self.height)
        layer?.addSublayer(fill)
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Intrinsic, because a height constraint would be re-added on every card rebuild.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    override func layout() {
        super.layout()
        apply()
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        layer?.backgroundColor = chrome.fill(.rest).cgColor
        fill.backgroundColor = chrome.accent.nsColor.cgColor
    }

    private func apply() {
        guard bounds.width > 0 else { return }
        if let fraction {
            fill.removeAnimation(forKey: "sweep")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.frame = CGRect(
                x: 0, y: 0, width: bounds.width * CGFloat(min(max(fraction, 0), 1)), height: bounds.height)
            CATransaction.commit()
        } else {
            startSweep()
        }
    }

    private func startSweep() {
        let segment = bounds.width * Self.sweepFraction
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0, width: segment, height: bounds.height)
        CATransaction.commit()
        guard fill.animation(forKey: "sweep") == nil, !Motion.isReduceMotionEnabled() else { return }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = segment / 2
        sweep.toValue = bounds.width - segment / 2
        sweep.duration = Self.sweepDuration
        sweep.autoreverses = true
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fill.add(sweep, forKey: "sweep")
    }
}
