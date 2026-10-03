import AppKit

final class HostRouteView: NSView {
    private static let lineSize = NSSize(width: 220, height: 24)
    private static let lineInset: CGFloat = 2
    private static let lineWidth: CGFloat = 1.6
    private static let idleDash: [NSNumber] = [2, 7]

    private let mac = RouteEndpointView(symbol: "laptopcomputer", name: "This Mac")
    private let destination: RouteEndpointView
    private let lineHost = NSView()
    private let line = CAShapeLayer()

    init(host: SSHHostID) {
        destination = RouteEndpointView(symbol: "server.rack", name: host.name)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        lineHost.wantsLayer = true
        lineHost.translatesAutoresizingMaskIntoConstraints = false
        let path = CGMutablePath()
        let midY = Self.lineSize.height / 2
        path.move(to: CGPoint(x: Self.lineInset, y: midY))
        path.addLine(to: CGPoint(x: Self.lineSize.width - Self.lineInset, y: midY))
        line.path = path
        line.lineWidth = Self.lineWidth
        line.lineCap = .round
        line.lineDashPattern = Self.idleDash
        line.fillColor = nil
        lineHost.layer?.addSublayer(line)

        addSubview(mac)
        addSubview(lineHost)
        addSubview(destination)
        NSLayoutConstraint.activate([
            mac.leadingAnchor.constraint(equalTo: leadingAnchor),
            mac.topAnchor.constraint(equalTo: topAnchor),
            mac.bottomAnchor.constraint(equalTo: bottomAnchor),
            lineHost.leadingAnchor.constraint(equalTo: mac.trailingAnchor),
            lineHost.widthAnchor.constraint(equalToConstant: Self.lineSize.width),
            lineHost.heightAnchor.constraint(equalToConstant: Self.lineSize.height),
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

    func setStatus(_ status: SSHHostStatus) { destination.setStatus(status) }

    func reapplyTheme() {
        mac.reapplyTheme()
        destination.reapplyTheme()
        line.strokeColor = Theme.current.chrome.ink(.muted).cgColor
    }

    var destinationForTesting: RouteEndpointView { destination }
    var lineStrokeForTesting: CGColor? { line.strokeColor }
}
