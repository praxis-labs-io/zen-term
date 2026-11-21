import AppKit

final class RouteEndpointView: NSView, ThemeReapplying {
    static let tileSide: CGFloat = ChromeMetrics.Height.xl
    static let columnWidth: CGFloat = 96
    private static let tileCornerRadius: CGFloat = ChromeMetrics.Radius.tile
    private static let tileToName: CGFloat = ChromeMetrics.Spacing.s12

    private let tile = NSView()
    private let symbol = NSImageView()
    private let name: NSTextField

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

        self.name.font = ChromeType.font(.small)
        self.name.alignment = .center
        self.name.lineBreakMode = .byTruncatingMiddle
        self.name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.name.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tile)
        addSubview(self.name)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.columnWidth),
            tile.topAnchor.constraint(equalTo: topAnchor),
            tile.centerXAnchor.constraint(equalTo: centerXAnchor),
            tile.widthAnchor.constraint(equalToConstant: Self.tileSide),
            tile.heightAnchor.constraint(equalToConstant: Self.tileSide),
            symbol.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            self.name.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: Self.tileToName),
            self.name.leadingAnchor.constraint(equalTo: leadingAnchor),
            self.name.trailingAnchor.constraint(equalTo: trailingAnchor),
            self.name.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        tile.layer?.backgroundColor = chrome.fill(.rest).cgColor
        tile.layer?.borderColor = chrome.fill(alpha: ChromeTheme.border).cgColor
        symbol.contentTintColor = chrome.ink(.subtle)
        name.textColor = chrome.ink(.muted)
    }

    var tileFillForTesting: CGColor? { tile.layer?.backgroundColor }
    var nameColorForTesting: NSColor? { name.textColor }
}
