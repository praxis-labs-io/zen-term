import AppKit

// The canvas for an SSH host that isn't connected: no panes, no tab bar, one Connect button.
final class HostConnectView: NSView {
    private static let iconSize: CGFloat = 28
    private static let spacing: CGFloat = 12

    let host: SSHHostID
    private let frameView = NSView()
    private let icon = NSImageView()
    private let message = NSTextField(labelWithString: "")
    let connectButton: AppButton

    init(host: SSHHostID, onConnect: @escaping () -> Void) {
        self.host = host
        connectButton = AppButton(title: "Connect", variant: .primary, onTap: onConnect)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        connectButton.isKeyboardFocusable = true
        connectButton.showsFocusOutline = true
        connectButton.setAccessibilityLabel("Connect to \(host.name)")

        frameView.translatesAutoresizingMaskIntoConstraints = false
        frameView.wantsLayer = true
        frameView.layer?.borderWidth = 1
        frameView.layer?.cornerRadius = PanelHostView.cornerRadius
        addSubview(frameView)

        icon.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.iconSize, weight: .light))
        message.stringValue = "Press ↵ to connect to \(host.name)."
        message.font = .systemFont(ofSize: 13)
        message.alignment = .center
        message.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [icon, message, connectButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        frameView.addSubview(stack)

        NSLayoutConstraint.activate([
            frameView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ChromeMetrics.windowGutter),
            frameView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ChromeMetrics.windowGutter),
            frameView.topAnchor.constraint(equalTo: topAnchor, constant: ChromeMetrics.topInset),
            frameView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: frameView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: frameView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: frameView.leadingAnchor, constant: Self.spacing),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: frameView.trailingAnchor, constant: -Self.spacing),
        ])
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        frameView.layer?.borderColor = chrome.fill(alpha: ChromeTheme.border).cgColor
        icon.contentTintColor = chrome.ink(.muted)
        message.textColor = chrome.ink(.muted)
        connectButton.reapplyTheme()
    }

    var messageForTesting: String { message.stringValue }
}
