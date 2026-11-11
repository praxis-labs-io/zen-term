import AppKit
import PaneKit

final class SplitDivider: NSView {
    let splitID: SplitID
    let axis: SplitAxis
    private let onDrag: (SplitID, SplitAxis, Double) -> Void
    private var grabOffset: CGFloat?

    init(splitID: SplitID, axis: SplitAxis, onDrag: @escaping (SplitID, SplitAxis, Double) -> Void) {
        self.splitID = splitID
        self.axis = axis
        self.onDrag = onDrag
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The window is movable by its background, so a press in the gutter would otherwise drag the window.
    override var mouseDownCanMoveWindow: Bool { false }

    private var resizeCursor: NSCursor { axis == .vertical ? .resizeLeftRight : .resizeUpDown }

    override func resetCursorRects() { addCursorRect(bounds, cursor: resizeCursor) }

    override func mouseDown(with event: NSEvent) {
        guard let container = superview else { return }
        let center = position(of: CGPoint(x: frame.midX, y: frame.midY), in: container)
        grabOffset = position(of: container.convert(event.locationInWindow, from: nil), in: container) - center
        resizeCursor.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grabOffset, let container = superview else { return }
        let extent = axis == .vertical ? container.bounds.width : container.bounds.height
        guard extent > 0 else { return }
        let pointer = position(of: container.convert(event.locationInWindow, from: nil), in: container)
        onDrag(splitID, axis, Double((pointer - grabOffset) / extent))
    }

    override func mouseUp(with event: NSEvent) {
        guard grabOffset != nil else { return }
        grabOffset = nil
        NSCursor.pop()
    }

    private func position(of point: CGPoint, in container: NSView) -> CGFloat {
        guard axis == .horizontal else { return point.x }
        return container.isFlipped ? point.y : container.bounds.height - point.y
    }
}
