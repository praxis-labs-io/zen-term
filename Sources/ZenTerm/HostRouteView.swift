import AppKit

final class HostRouteView: NSView {
    static let preferredLineLength: CGFloat = 120
    private static let lineHeight: CGFloat = ChromeMetrics.Height.sm
    private static let minimumLineLength: CGFloat = 24
    // Under the window's own sizing priorities, so a narrow canvas shortens the line rather than widening the window.
    private static let lineWidthPreference = NSLayoutConstraint.Priority(rawValue: 490)
    private static let lineInset: CGFloat = ChromeMetrics.Spacing.s2
    private static let lineWidth: CGFloat = ChromeMetrics.Border.paneFocus
    private static let idleDash: [NSNumber] = [2, 7]

    private let mac = RouteEndpointView(symbol: "laptopcomputer", name: "Client")
    private let destination = RouteEndpointView(symbol: "server.rack", name: "Host")
    private let lineHost = NSView()
    private let line = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        lineHost.wantsLayer = true
        lineHost.translatesAutoresizingMaskIntoConstraints = false
        line.lineWidth = Self.lineWidth
        line.lineCap = .round
        line.lineDashPattern = Self.idleDash
        line.fillColor = nil
        lineHost.layer?.addSublayer(line)

        let preferredWidth = lineHost.widthAnchor.constraint(equalToConstant: Self.preferredLineLength)
        preferredWidth.priority = Self.lineWidthPreference
        addSubview(mac)
        addSubview(lineHost)
        addSubview(destination)
        NSLayoutConstraint.activate([
            mac.leadingAnchor.constraint(equalTo: leadingAnchor),
            mac.topAnchor.constraint(equalTo: topAnchor),
            mac.bottomAnchor.constraint(equalTo: bottomAnchor),
            lineHost.leadingAnchor.constraint(equalTo: mac.trailingAnchor),
            preferredWidth,
            lineHost.widthAnchor.constraint(lessThanOrEqualToConstant: Self.preferredLineLength),
            lineHost.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumLineLength),
            lineHost.heightAnchor.constraint(equalToConstant: Self.lineHeight),
            lineHost.centerYAnchor.constraint(
                equalTo: topAnchor, constant: RouteEndpointView.tileSide / 2),
            destination.leadingAnchor.constraint(equalTo: lineHost.trailingAnchor),
            destination.trailingAnchor.constraint(equalTo: trailingAnchor),
            destination.topAnchor.constraint(equalTo: topAnchor),
            destination.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let span = Self.evenDashSpan(within: lineHost.bounds.width)
        let midY = Self.lineHeight / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: span.lowerBound, y: midY))
        path.addLine(to: CGPoint(x: span.upperBound, y: midY))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.path = path
        CATransaction.commit()
    }

    // Ends the line on a whole dash and splits the remainder, so both ends sit the same distance from their tile.
    private static func evenDashSpan(within width: CGFloat) -> ClosedRange<CGFloat> {
        let available = max(0, width - 2 * lineInset)
        let dash = CGFloat(truncating: idleDash[0])
        let space = CGFloat(truncating: idleDash[1])
        let dashes = max(1, ((available + space) / (dash + space)).rounded(.down))
        let drawn = min(available, dashes * (dash + space) - space)
        let start = lineInset + (available - drawn) / 2
        return start...(start + drawn)
    }

    func setStatus(_ status: SSHHostStatus) { destination.setStatus(status) }

    func reapplyTheme() {
        mac.reapplyTheme()
        destination.reapplyTheme()
        line.strokeColor = Theme.current.chrome.ink(.muted).cgColor
    }

    var destinationForTesting: RouteEndpointView { destination }
    var lineStrokeForTesting: CGColor? { line.strokeColor }
    var lineWidthForTesting: CGFloat { lineHost.frame.width }
}
