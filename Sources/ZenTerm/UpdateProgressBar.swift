import AppKit

/// A theme-driven download bar for `UpdateCardView`. `NSProgressIndicator` tints from
/// `effectiveAppearance`, which the chrome bans, so this is a plain two-layer bar:
/// a neutral ink track under an accent fill. `fraction` nil means the expected length isn't
/// known yet, and an accent segment sweeps across to read as working.
final class UpdateProgressBar: NSView {
    private let fill = CALayer()
    private static let sweepFraction: CGFloat = 0.3  // width of the indeterminate segment

    /// 0…1 fills the bar; nil runs the indeterminate sweep.
    var fraction: Double? {
        didSet {
            guard fraction != oldValue else { return }
            apply()
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.masksToBounds = true
        fill.cornerRadius = 2
        layer?.addSublayer(fill)
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A fixed 4pt bar. Vending the height intrinsically (rather than a self-owned height
    /// constraint the card re-adds each rebuild) keeps the download hot path from leaking
    /// constraints; width comes from a constraint to the card's column.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 4) }

    override func layout() {
        super.layout()
        apply()
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        layer?.backgroundColor = chrome.ink(alpha: 0.09).cgColor
        fill.backgroundColor = chrome.accent.nsColor.cgColor
    }

    private func apply() {
        guard bounds.width > 0 else { return }
        if let fraction {
            fill.removeAnimation(forKey: "sweep")
            // No implicit animation on the frame set — the bar advances as data arrives, and CA's
            // default would lag each step behind the real progress.
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
        sweep.duration = 0.9
        sweep.autoreverses = true
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fill.add(sweep, forKey: "sweep")
    }
}
