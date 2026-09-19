import QuartzCore

// An alpha-only gradient mask that fades content out toward the edges of one axis; theme-independent.
@MainActor
final class EdgeFade {
    enum Axis { case horizontal, vertical }

    let layer = CAGradientLayer()
    private let axis: Axis

    init(axis: Axis) {
        self.axis = axis
        switch axis {
        case .horizontal:
            layer.startPoint = CGPoint(x: 0, y: 0.5)
            layer.endPoint = CGPoint(x: 1, y: 0.5)
        case .vertical:
            layer.startPoint = CGPoint(x: 0.5, y: 0)
            layer.endPoint = CGPoint(x: 0.5, y: 1)
        }
    }

    func update(frame: CGRect, start: CGFloat, end: CGFloat) {
        let length = axis == .horizontal ? frame.width : frame.height
        let opaque = CGColor(gray: 1, alpha: 1)
        let clear = CGColor(gray: 1, alpha: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        layer.locations =
            length > 0
            ? [0, NSNumber(value: Double(start / length)), NSNumber(value: Double(1 - end / length)), 1]
            : [0, 0, 1, 1]
        layer.colors = [start > 0 ? clear : opaque, opaque, opaque, end > 0 ? clear : opaque]
        CATransaction.commit()
    }
}
