import AppKit

// `NSProgressIndicator` tints from `effectiveAppearance`, which the chrome bans.
final class Spinner: NSView {
    private let pixels: [CALayer] = (0..<6).map { _ in CALayer() }
    private static let size: CGFloat = 13
    private static let pixelSize: CGFloat = 3
    private static let pixelGap: CGFloat = 2
    private static let frameDuration: CFTimeInterval = 0.1
    private static let stepKey = "zenterm.spin"
    private static let clockwiseCells: [(column: Int, rowFromTop: Int)] = [
        (0, 0), (1, 0), (1, 1), (1, 2), (0, 2), (0, 1),
    ]

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
        pixels.forEach { layer?.addSublayer($0) }
        pixels.first?.opacity = 0
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.size, height: Self.size)
    }

    override func layout() {
        super.layout()
        let pitch = Self.pixelSize + Self.pixelGap
        let gridWidth = 2 * Self.pixelSize + Self.pixelGap
        let gridHeight = 3 * Self.pixelSize + 2 * Self.pixelGap
        let origin = CGPoint(
            x: ((bounds.width - gridWidth) / 2).rounded(), y: ((bounds.height - gridHeight) / 2).rounded())
        for (pixel, cell) in zip(pixels, Self.clockwiseCells) {
            pixel.frame = CGRect(
                x: origin.x + CGFloat(cell.column) * pitch, y: origin.y + CGFloat(2 - cell.rowFromTop) * pitch,
                width: Self.pixelSize, height: Self.pixelSize)
        }
        applySpin()
    }

    func reapplyTheme() {
        let accent = Theme.current.chrome.accent.nsColor.cgColor
        pixels.forEach { $0.backgroundColor = accent }
    }

    private func applySpin() {
        if isSpinning, pixels.first?.animation(forKey: Self.stepKey) != nil { return }
        pixels.forEach { $0.removeAnimation(forKey: Self.stepKey) }
        guard isSpinning, !Motion.isReduceMotionEnabled() else { return }
        let frames = pixels.count
        let keyTimes = (0...frames).map { NSNumber(value: Double($0) / Double(frames)) }
        for (index, pixel) in pixels.enumerated() {
            let step = CAKeyframeAnimation(keyPath: "opacity")
            step.calculationMode = .discrete
            step.keyTimes = keyTimes
            step.values = (0..<frames).map { $0 == index ? 0 : 1 }
            step.duration = Self.frameDuration * Double(frames)
            step.repeatCount = .infinity
            pixel.add(step, forKey: Self.stepKey)
        }
    }
}
