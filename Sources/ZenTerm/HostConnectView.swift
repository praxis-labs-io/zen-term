import AppKit

// The canvas for an SSH host that isn't connected: the route from this Mac to the host, and Connect on ↵.
final class HostConnectView: NSView {
    private static let edgeSpacing: CGFloat = 12
    private static let routeToEyebrow: CGFloat = 34
    private static let eyebrowToTitle: CGFloat = 12
    private static let titleToDestination: CGFloat = 10
    private static let destinationToDetail: CGFloat = 14
    private static let detailToButton: CGFloat = 30
    private static let detailMaxWidth: CGFloat = 420
    private static let eyebrowFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
    private static let eyebrowKern: CGFloat = 1
    static let titlePointSize: CGFloat = 22
    private static let titleFont = NSFont.systemFont(ofSize: titlePointSize, weight: .semibold)
    private static let destinationFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private static let detailFont = NSFont.systemFont(ofSize: 13)

    // A short window drops the diagram first, then the eyebrow, so the action never leaves the screen.
    private static let routeVisibility = NSStackView.VisibilityPriority(rawValue: 500)
    private static let eyebrowVisibility = NSStackView.VisibilityPriority(rawValue: 600)

    let host: SSHHostID
    private var name: String
    private let onConnect: () -> Void
    private var status: SSHHostStatus
    private let grid = DotGridView()
    private let route: HostRouteView
    private let eyebrow = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let destinationLine = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let connectButton: AppButton
    private let stack = NSStackView()
    private let panel: PanelHostView
    private let content = NSView()
    private var gutterConstraints: [NSLayoutConstraint] = []

    init(
        host: SSHHostID, name: String, status: SSHHostStatus, destination: String?, onConnect: @escaping () -> Void,
        onFocusRequest: @escaping () -> Void
    ) {
        self.host = host
        self.name = name
        self.status = status
        self.onConnect = onConnect
        route = HostRouteView()
        connectButton = AppButton(
            title: "Connect", variant: .primary, size: .large, shortcut: "⏎", onTap: onConnect)
        panel = PanelHostView(content: content, meta: nil, onFocusRequest: onFocusRequest)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        eyebrow.maximumNumberOfLines = 1
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        destinationLine.font = Self.destinationFont
        destinationLine.alignment = .center
        destinationLine.lineBreakMode = .byTruncatingMiddle
        destinationLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = Self.detailFont
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = Self.detailMaxWidth
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        [route, eyebrow, title, destinationLine, detail, connectButton].forEach(stack.addArrangedSubview)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.detachesHiddenViews = true
        stack.setCustomSpacing(Self.routeToEyebrow, after: route)
        stack.setCustomSpacing(Self.eyebrowToTitle, after: eyebrow)
        stack.setCustomSpacing(Self.titleToDestination, after: title)
        stack.setCustomSpacing(Self.destinationToDetail, after: destinationLine)
        stack.setCustomSpacing(Self.detailToButton, after: detail)
        stack.setVisibilityPriority(Self.routeVisibility, for: route)
        stack.setVisibilityPriority(Self.eyebrowVisibility, for: eyebrow)
        stack.setClippingResistancePriority(.defaultLow, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        content.addSubview(stack)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        gutterConstraints = [
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.windowGutter),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChromeMetrics.windowGutter),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: ChromeMetrics.topInset),
        ]
        NSLayoutConstraint.activate(gutterConstraints)
        let centered = stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            grid.topAnchor.constraint(equalTo: content.topAnchor),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            centered,
            stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: Self.edgeSpacing),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -Self.edgeSpacing),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: Self.edgeSpacing),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -Self.edgeSpacing),
        ])
        content.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(fitDetailToWidth), name: NSView.frameDidChangeNotification, object: content)
        route.setStatus(status)
        setDestination(destination)
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard KeyboardFocus.isReturn(event) else { return super.keyDown(with: event) }
        onConnect()
    }

    func setHaloVisible(_ visible: Bool) { panel.isFocused = visible }

    func setStatus(_ status: SSHHostStatus) {
        guard status != self.status else { return }
        self.status = status
        route.setStatus(status)
        applyDetail()
    }

    func setName(_ name: String) {
        guard name != self.name else { return }
        self.name = name
        applyName()
        applyDetail()
    }

    func setDestination(_ text: String?) {
        destinationLine.stringValue = text ?? ""
        destinationLine.isHidden = text == nil
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        grid.reapplyTheme()
        route.reapplyTheme()
        eyebrow.attributedStringValue = Self.line(
            "SSH HOST", font: Self.eyebrowFont, kern: Self.eyebrowKern, color: chrome.ink(.faint),
            breaking: .byClipping)
        applyName()
        destinationLine.textColor = chrome.ink(.muted)
        applyDetail()
        connectButton.reapplyTheme()
        panel.reapplyTheme()
    }

    func reapplyChromeLayout() {
        gutterConstraints[0].constant = ChromeMetrics.windowGutter
        gutterConstraints[1].constant = -ChromeMetrics.windowGutter
        gutterConstraints[2].constant = ChromeMetrics.topInset
        panel.reapplyChromeLayout()
    }

    @objc private func fitDetailToWidth() {
        let width = min(Self.detailMaxWidth, content.frame.width - Self.edgeSpacing * 2)
        guard width > 0, detail.preferredMaxLayoutWidth != width else { return }
        detail.preferredMaxLayoutWidth = width
        detail.invalidateIntrinsicContentSize()
    }

    private func applyName() {
        title.attributedStringValue = Self.line(
            "Connect to \(name)", font: Self.titleFont, kern: 0, color: Theme.current.chrome.foreground.nsColor,
            breaking: .byTruncatingMiddle)
        connectButton.setAccessibilityLabel("Connect to \(name)")
    }

    private func applyDetail() {
        detail.stringValue =
            status == .offline ? "\(name) appears offline. Connect anyway?" : "Signs in with your ssh config."
        detail.textColor = Theme.current.chrome.ink(.muted)
    }

    private static func line(
        _ text: String, font: NSFont, kern: CGFloat, color: NSColor, breaking: NSLineBreakMode
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = breaking
        return NSAttributedString(
            string: text,
            attributes: [.font: font, .kern: kern, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    var titleForTesting: String { title.stringValue }
    var detailForTesting: String { detail.stringValue }
    var detailFieldForTesting: NSTextField { detail }
    var destinationForTesting: String? { destinationLine.isHidden ? nil : destinationLine.stringValue }
    var routeForTesting: HostRouteView { route }
    var detachedForTesting: [NSView] { stack.detachedViews }
    var panelForTesting: PanelHostView { panel }
    var connectButtonForTesting: AppButton { connectButton }
}
