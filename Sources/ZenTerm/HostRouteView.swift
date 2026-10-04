import AppKit

final class HostRouteView: NSView {
    static let preferredLineLength: CGFloat = 120
    private static let lineHeight: CGFloat = 24
    private static let minimumLineWidth: CGFloat = 24
    // Under the window's own sizing priorities, so a narrow canvas shortens the line rather than widening the window.
    private static let lineWidthPreference = NSLayoutConstraint.Priority(rawValue: 490)
    private static let lineInset: CGFloat = 2
    private static let lineWidth: CGFloat = 1.6
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
            lineHost.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumLineWidth),
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
        let width = lineHost.bounds.width
        let midY = Self.lineHeight / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: Self.lineInset, y: midY))
        path.addLine(to: CGPoint(x: max(Self.lineInset, width - Self.lineInset), y: midY))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.path = path
        CATransaction.commit()
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
