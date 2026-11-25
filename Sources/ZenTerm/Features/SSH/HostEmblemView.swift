import AppKit

// The Connect screen's host emblem: the host's signature as a dot matrix on a rounded tile.
final class HostEmblemView: NSView, ThemeReapplying {
    static let tileSide: CGFloat = 84
    // swiftlint:disable:next untokened_radius
    private static let cellRadius: CGFloat = 2
    private static let cellSide: CGFloat = 7
    private static let cellGap = ChromeMetrics.Spacing.s4

    private let lit: [Bool]
    private let cells: [CALayer]
    private let sheen = CAGradientLayer()
    private var isDimmed = false

    init(host: SSHHostID) {
        lit = HostSignature.cells(of: host)
        cells = lit.map { _ in CALayer() }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.tileSide, height: Self.tileSide))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.icon(Self.tileSide)
        layer?.cornerCurve = .continuous
        layer?.borderWidth = ChromeMetrics.Border.width
        layer?.masksToBounds = true
        sheen.frame = bounds
        ChipSheen.shape(sheen)
        layer?.addSublayer(sheen)
        let grid = CGFloat(HostSignature.side) * Self.cellSide + CGFloat(HostSignature.side - 1) * Self.cellGap
        let origin = (Self.tileSide - grid) / 2
        for (index, cell) in cells.enumerated() {
            let row = index / HostSignature.side
            let column = index % HostSignature.side
            cell.frame = NSRect(
                x: origin + CGFloat(column) * (Self.cellSide + Self.cellGap),
                y: origin + CGFloat(HostSignature.side - 1 - row) * (Self.cellSide + Self.cellGap),
                width: Self.cellSide, height: Self.cellSide)
            cell.cornerRadius = Self.cellRadius
            layer?.addSublayer(cell)
        }
        setAccessibilityElement(false)
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.tileSide, height: Self.tileSide) }

    func setDimmed(_ dimmed: Bool) {
        guard dimmed != isDimmed else { return }
        isDimmed = dimmed
        reapplyTheme()
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        layer?.backgroundColor = chrome.background.nsColor.cgColor
        layer?.borderColor = chrome.fill(alpha: ChromeTheme.border).cgColor
        let on = chrome.ink(isDimmed ? .muted : .normal).cgColor
        let off = chrome.fill(.active).cgColor
        for (cell, isLit) in zip(cells, lit) { cell.backgroundColor = isLit ? on : off }
    }

    var litForTesting: [Bool] { lit }
    var cellColorsForTesting: [CGColor?] { cells.map(\.backgroundColor) }
    var tileFillForTesting: CGColor? { layer?.backgroundColor }
    var hasSheenUnderCellsForTesting: Bool {
        layer?.sublayers?.first === sheen && sheen.colors?.count == ChipSheen.colors.count
    }
}
