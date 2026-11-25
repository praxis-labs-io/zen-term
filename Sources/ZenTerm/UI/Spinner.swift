import AppKit
import TerminalKit

// `NSProgressIndicator` tints from `effectiveAppearance`, which the chrome bans.
final class Spinner: NSView, ThemeReapplying {
    struct Frame {
        let rotation: CGFloat
        let arcLength: CGFloat
    }

    private static let size: CGFloat = 13
    // The ring's own geometry, not a chrome corner radius.
    // swiftlint:disable:next untokened_radius
    private static let ringRadius: CGFloat = 5.25
    private static let ringWidth: CGFloat = 1.5
    private static let turnKey = "zenterm.spin.turn"
    private static let stretchKey = "zenterm.spin.stretch"

    // Every spinner steps on this one grid so the window redraws 30 times a second however many spin.
    static let frameInterval: CFTimeInterval = 1.0 / 30
    private static let turnPeriod: CFTimeInterval = 1.5
    private static let stretchPeriod: CFTimeInterval = 2
    private static let shortestArc: CGFloat = 0.05
    private static let longestArc: CGFloat = 0.8
    private static let leadAtLongest: CGFloat = 0.15

    // 6 s is the first moment the 1.5 s turn and the 2 s stretch line up again.
    private static let loopFrames = 180
    static let frames: [Frame] = (0..<loopFrames).map(frame(at:))

    private static let loopDuration = Double(loopFrames) * frameInterval
    private static let keyTimes = (0...loopFrames).map { NSNumber(value: Double($0) / Double(loopFrames)) }

    private let arc = CAShapeLayer()
    private let stillDot = StateDot()

    var role: KeyPath<ChromeTheme, TerminalColor> = \.accent { didSet { reapplyTheme() } }

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
        arc.fillColor = nil
        arc.lineWidth = Self.ringWidth
        arc.lineCap = .round
        layer?.addSublayer(arc)
        arc.strokeEnd = Self.shortestArc
        stillDot.translatesAutoresizingMaskIntoConstraints = false
        stillDot.isHidden = true
        addSubview(stillDot)
        NSLayoutConstraint.activate([
            stillDot.centerXAnchor.constraint(equalTo: centerXAnchor),
            stillDot.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.size, height: Self.size)
    }

    var stillDotStateForTesting: StateDot.State? { stillDot.isHidden ? nil : stillDot.state }
    var arcForTesting: CAShapeLayer { arc }

    override func layout() {
        super.layout()
        let box = CGRect(
            x: ((bounds.width - Self.size) / 2).rounded(), y: ((bounds.height - Self.size) / 2).rounded(),
            width: Self.size, height: Self.size)
        let ring = CGMutablePath()
        ring.addArc(
            center: CGPoint(x: Self.size / 2, y: Self.size / 2), radius: Self.ringRadius, startAngle: 0,
            endAngle: -2 * .pi, clockwise: true)
        withoutImplicitMotion {
            arc.frame = box
            arc.path = ring
        }
        applySpin()
    }

    func reapplyTheme() {
        withoutImplicitMotion { arc.strokeColor = Theme.current.chrome[keyPath: role].nsColor.cgColor }
        if !stillDot.isHidden { stillDot.state = stillDotState }
    }

    private var stillDotState: StateDot.State { role == \ChromeTheme.working ? .working : .live }

    private func withoutImplicitMotion(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    private func applySpin() {
        let showsStillDot = isSpinning && Motion.isReduceMotionEnabled()
        stillDot.state = showsStillDot ? stillDotState : nil
        stillDot.isHidden = !showsStillDot
        withoutImplicitMotion { arc.isHidden = showsStillDot }
        if isSpinning, !showsStillDot, arc.animation(forKey: Self.turnKey) != nil { return }
        arc.removeAnimation(forKey: Self.turnKey)
        arc.removeAnimation(forKey: Self.stretchKey)
        guard isSpinning, !showsStillDot else { return }
        let firstTick = (CACurrentMediaTime() / Self.frameInterval).rounded(.up) * Self.frameInterval
        let beginTime = arc.convertTime(firstTick, from: nil)
        let turn = Self.step("transform.rotation.z", Self.frames.map { NSNumber(value: Double($0.rotation)) })
        let stretch = Self.step("strokeEnd", Self.frames.map { NSNumber(value: Double($0.arcLength)) })
        for (key, step) in [(Self.turnKey, turn), (Self.stretchKey, stretch)] {
            step.beginTime = beginTime
            arc.add(step, forKey: key)
        }
    }

    private static func step(_ keyPath: String, _ values: [NSNumber]) -> CAKeyframeAnimation {
        let step = CAKeyframeAnimation(keyPath: keyPath)
        step.calculationMode = .discrete
        step.keyTimes = keyTimes
        step.values = values
        step.duration = loopDuration
        step.repeatCount = .infinity
        step.fillMode = .backwards
        return step
    }

    private static func frame(at index: Int) -> Frame {
        let time = Double(index) * frameInterval
        let stretches = (time / stretchPeriod).rounded(.down)
        let phase = CGFloat(time / stretchPeriod - stretches)
        let growing = phase < 0.5
        let progress = growing ? phase * 2 : (phase - 0.5) * 2
        let arcLength =
            growing
            ? shortestArc + (longestArc - shortestArc) * progress
            : longestArc - (longestArc - shortestArc) * progress
        let lead = growing ? leadAtLongest * progress : leadAtLongest + (1 - leadAtLongest) * progress
        let turns = CGFloat(time / turnPeriod + stretches) + lead
        return Frame(rotation: -2 * .pi * turns, arcLength: arcLength)
    }
}
