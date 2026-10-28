import AppKit

final class RouteEndpointView: NSView, ThemeReapplying {
    static let tileSide: CGFloat = ChromeMetrics.Height.xl
    static let columnWidth: CGFloat = 96
    private static let tileCornerRadius: CGFloat = ChromeMetrics.Radius.tile
    private static let tileToName: CGFloat = ChromeMetrics.Spacing.s12
    private static let badgeSide: CGFloat = 12
    private static let badgeOverhang: CGFloat = ChromeMetrics.Spacing.s2
    private static let statusMarkSide: CGFloat = 6.2

    private let tile = NSView()
    private let symbol = NSImageView()
    private let name: NSTextField
    private let badge = NSView()
    private let statusMark = CAShapeLayer()
    private(set) var status: SSHHostStatus?

    init(symbol symbolName: String, name: String) {
        self.name = NSTextField(labelWithString: name)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        tile.wantsLayer = true
        tile.layer?.cornerRadius = Self.tileCornerRadius
        tile.layer?.borderWidth = ChromeMetrics.Border.width
        tile.translatesAutoresizingMaskIntoConstraints = false
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        symbol.symbolConfiguration = .init(pointSize: ChromeMetrics.Icon.xl, weight: .light)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(symbol)

        badge.wantsLayer = true
        badge.layer?.cornerRadius = ChromeMetrics.Radius.capsule(Self.badgeSide)
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        let inset = (Self.badgeSide - Self.statusMarkSide) / 2
        statusMark.path = CGPath(
            ellipseIn: CGRect(x: inset, y: inset, width: Self.statusMarkSide, height: Self.statusMarkSide),
            transform: nil)
        badge.layer?.addSublayer(statusMark)

        self.name.font = ChromeType.font(.small)
        self.name.alignment = .center
        self.name.lineBreakMode = .byTruncatingMiddle
        self.name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.name.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tile)
        addSubview(badge)
        addSubview(self.name)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.columnWidth),
            tile.topAnchor.constraint(equalTo: topAnchor),
            tile.centerXAnchor.constraint(equalTo: centerXAnchor),
            tile.widthAnchor.constraint(equalToConstant: Self.tileSide),
            tile.heightAnchor.constraint(equalToConstant: Self.tileSide),
            symbol.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: Self.badgeSide),
            badge.heightAnchor.constraint(equalToConstant: Self.badgeSide),
            badge.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: Self.badgeOverhang),
            badge.topAnchor.constraint(equalTo: tile.topAnchor, constant: -Self.badgeOverhang),
            self.name.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: Self.tileToName),
            self.name.leadingAnchor.constraint(equalTo: leadingAnchor),
            self.name.trailingAnchor.constraint(equalTo: trailingAnchor),
            self.name.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setStatus(_ status: SSHHostStatus?) {
        self.status = status
        badge.isHidden = status == nil
        reapplyTheme()
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        tile.layer?.backgroundColor = chrome.fill(.rest).cgColor
        tile.layer?.borderColor = chrome.fill(alpha: ChromeTheme.border).cgColor
        symbol.contentTintColor = chrome.ink(.subtle)
        name.textColor = chrome.ink(.muted)
        badge.layer?.backgroundColor = chrome.background.nsColor.cgColor
        let ink = status?.ink.cgColor
        let isHollow = status == .offline
        statusMark.fillColor = isHollow ? nil : ink
        statusMark.strokeColor = isHollow ? ink : nil
        statusMark.lineWidth = ChromeMetrics.Border.width
    }

    var statusMarkForTesting: (fill: CGColor?, stroke: CGColor?) { (statusMark.fillColor, statusMark.strokeColor) }
}
