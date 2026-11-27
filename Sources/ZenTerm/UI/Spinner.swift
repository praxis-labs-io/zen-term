import AppKit
import TerminalKit

// `NSProgressIndicator` tints from `effectiveAppearance`, which the chrome bans.
final class Spinner: NSView, ThemeReapplying {
    private static let size: CGFloat = 13
    private static let ringRadius: CGFloat = 5
    private static let dotDiameter: CGFloat = 2.25
    private static let dotCount = 8
    // The lit dot, then its fading tail; every other dot rests at the last value.
    private static let tailOpacities: [Float] = [1, 0.7, 0.45, 0.2]

    // Every spinner steps on one main-thread timer, so a window redraws 10 times a second however many spin.
    static let stepsPerSecond: Double = 10

    private static let spinning = NSHashTable<Spinner>.weakObjects()
    private static var clock: Timer?
    private static var step = 0

    private let dots: [CALayer] = (0..<dotCount).map { _ in CALayer() }
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
        for dot in dots {
            // swiftlint:disable:next untokened_radius
            dot.cornerRadius = Self.dotDiameter / 2
            layer?.addSublayer(dot)
        }
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
    var dotsForTesting: [CALayer] { dots }
    var isOnClockForTesting: Bool { Self.spinning.contains(self) }
    static func tickForTesting() { tick() }

    override func layout() {
        super.layout()
        let center = CGPoint(x: (bounds.width / 2).rounded(), y: (bounds.height / 2).rounded())
        withoutImplicitMotion {
            for (index, dot) in dots.enumerated() {
                let angle = CGFloat.pi / 2 - 2 * .pi * CGFloat(index) / CGFloat(Self.dotCount)
                dot.frame = CGRect(
                    x: center.x + Self.ringRadius * cos(angle) - Self.dotDiameter / 2,
                    y: center.y + Self.ringRadius * sin(angle) - Self.dotDiameter / 2,
                    width: Self.dotDiameter, height: Self.dotDiameter)
            }
        }
        applySpin()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applySpin()
    }

    func reapplyTheme() {
        let color = Theme.current.chrome[keyPath: role].nsColor.cgColor
        withoutImplicitMotion { dots.forEach { $0.backgroundColor = color } }
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
        withoutImplicitMotion { dots.forEach { $0.isHidden = showsStillDot } }
        if isSpinning, !showsStillDot, window != nil {
            Self.spinning.add(self)
        } else {
            Self.spinning.remove(self)
        }
        showStep(Self.step)
        Self.runClockWhileNeeded()
    }

    private func showStep(_ step: Int) {
        withoutImplicitMotion {
            for (index, dot) in dots.enumerated() {
                let behind = (step - index + Self.dotCount) % Self.dotCount
                dot.opacity = Self.tailOpacities[min(behind, Self.tailOpacities.count - 1)]
            }
        }
    }

    private static func runClockWhileNeeded() {
        if spinning.allObjects.isEmpty {
            clock?.invalidate()
            clock = nil
        } else if clock == nil {
            let timer = Timer(timeInterval: 1 / stepsPerSecond, repeats: true) { _ in
                MainActor.assumeIsolated { tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
        }
    }

    private static func tick() {
        step = (step + 1) % dotCount
        for spinner in spinning.allObjects { spinner.showStep(step) }
        runClockWhileNeeded()
    }
}
