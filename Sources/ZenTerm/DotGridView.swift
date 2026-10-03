import AppKit

final class DotGridView: NSView {
    static let pitch: CGFloat = 24
    static let dotRadius: CGFloat = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        Theme.current.chrome.fill(alpha: ChromeTheme.gridDot).setFill()
        let pitch = Self.pitch
        let side = Self.dotRadius * 2
        let firstColumn = Int((dirtyRect.minX / pitch).rounded(.down))
        let lastColumn = Int((dirtyRect.maxX / pitch).rounded(.up))
        let firstRow = Int((dirtyRect.minY / pitch).rounded(.down))
        let lastRow = Int((dirtyRect.maxY / pitch).rounded(.up))
        let dots = NSBezierPath()
        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn {
                let center = NSPoint(x: (CGFloat(column) + 0.5) * pitch, y: (CGFloat(row) + 0.5) * pitch)
                dots.appendOval(
                    in: NSRect(x: center.x - Self.dotRadius, y: center.y - Self.dotRadius, width: side, height: side))
            }
        }
        dots.fill()
    }

    func reapplyTheme() { needsDisplay = true }
}
