import AppKit

// The canvas for an SSH host that isn't connected: one panel, framed like a pane, that connects on ↵.
final class HostConnectView: NSView {
    private static let spacing: CGFloat = 12
    private static let iconToMessage: CGFloat = 16
    private static let messageToButton: CGFloat = 20

    let host: SSHHostID
    private let onConnect: () -> Void
    private let icon = IconBadge(symbol: "server.rack", accessibilityDescription: nil, size: .large) { $0.muted }
    private let message = NSTextField(labelWithString: "")
    private let connectButton: AppButton
    private let panel: PanelHostView
    private var gutterConstraints: [NSLayoutConstraint] = []

    init(host: SSHHostID, onConnect: @escaping () -> Void, onFocusRequest: @escaping () -> Void) {
        self.host = host
        self.onConnect = onConnect
        connectButton = AppButton(title: "Connect", variant: .primary, onTap: onConnect)
        let content = NSView()
        panel = PanelHostView(content: content, meta: nil, onFocusRequest: onFocusRequest)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        connectButton.setAccessibilityLabel("Connect to \(host.name)")

        message.stringValue = "Connect to \(host.name)"
        message.font = .systemFont(ofSize: 13)
        message.alignment = .center
        message.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [icon, message, connectButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.setCustomSpacing(Self.iconToMessage, after: icon)
        stack.setCustomSpacing(Self.messageToButton, after: message)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        gutterConstraints = [
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.windowGutter),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChromeMetrics.windowGutter),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: ChromeMetrics.topInset),
        ]
        NSLayoutConstraint.activate(gutterConstraints)
        NSLayoutConstraint.activate([
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: Self.spacing),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -Self.spacing),
        ])
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard KeyboardFocus.isReturn(event) else { return super.keyDown(with: event) }
        onConnect()
    }

    func setHaloVisible(_ visible: Bool) { panel.isFocused = visible }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        icon.reapplyTheme()
        message.textColor = chrome.ink(.muted)
        connectButton.reapplyTheme()
        panel.reapplyTheme()
    }

    func reapplyChromeLayout() {
        gutterConstraints[0].constant = ChromeMetrics.windowGutter
        gutterConstraints[1].constant = -ChromeMetrics.windowGutter
        gutterConstraints[2].constant = ChromeMetrics.topInset
        panel.reapplyChromeLayout()
    }

    var messageForTesting: String { message.stringValue }
    var panelForTesting: PanelHostView { panel }
    var connectButtonForTesting: AppButton { connectButton }
}
