import AppKit

// The canvas for an SSH host that isn't connected: its emblem, name, address and status, and Connect on ↵.
final class HostConnectView: NSView, ThemeReapplying {
    private static let edgeSpacing = ChromeMetrics.Spacing.s12
    private static let emblemToName = ChromeMetrics.Spacing.s24
    private static let nameToAddress = ChromeMetrics.Spacing.s6
    private static let addressToStatus = ChromeMetrics.Spacing.s12
    private static let statusToButton = ChromeMetrics.Spacing.s24
    private static let contentMaxWidth: CGFloat = 420
    private static let returnKey = "⏎"

    // A short window drops the emblem first, so the action never leaves the screen.
    private static let emblemVisibility = NSStackView.VisibilityPriority(rawValue: 500)

    let host: SSHHostID
    private var name: String
    private let onConnect: () -> Void
    private var status: SSHHostStatus
    private let emblem: HostEmblemView
    private let nameLine = NSTextField(labelWithString: "")
    private let addressLine = NSTextField(labelWithString: "")
    private let onlineDot = StateDot(.online)
    private let statusWord = NSTextField(labelWithString: "")
    private let statusLine = NSStackView()
    private let connectButton: AppButton
    private let connectAnywayButton: AppButton
    private let hints = HintFooter([], placement: .centered)
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
        emblem = HostEmblemView(host: host)
        connectButton = AppButton(
            title: "Connect", variant: .primary, onTap: onConnect)
        connectAnywayButton = AppButton(
            title: "Connect Anyway", variant: .secondary, onTap: onConnect)
        panel = PanelHostView(content: content, meta: nil, fillsContent: true, onFocusRequest: onFocusRequest)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        nameLine.font = ChromeType.font(.display)
        nameLine.alignment = .center
        nameLine.lineBreakMode = .byTruncatingTail
        nameLine.maximumNumberOfLines = 1
        nameLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addressLine.font = ChromeType.font(.small, face: .mono)
        addressLine.alignment = .center
        addressLine.lineBreakMode = .byTruncatingMiddle
        addressLine.maximumNumberOfLines = 1
        addressLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusWord.font = ChromeType.font(.small)
        statusWord.alignment = .center
        statusLine.orientation = .horizontal
        statusLine.alignment = .centerY
        statusLine.spacing = ChromeMetrics.Spacing.s8
        statusLine.detachesHiddenViews = true
        [onlineDot, statusWord].forEach { statusLine.addView($0, in: .center) }

        [emblem, nameLine, addressLine, statusLine, connectButton, connectAnywayButton]
            .forEach(stack.addArrangedSubview)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.detachesHiddenViews = true
        stack.setCustomSpacing(Self.emblemToName, after: emblem)
        stack.setCustomSpacing(Self.nameToAddress, after: nameLine)
        stack.setCustomSpacing(Self.addressToStatus, after: addressLine)
        stack.setCustomSpacing(Self.statusToButton, after: statusLine)
        stack.setVisibilityPriority(Self.emblemVisibility, for: emblem)
        stack.setClippingResistancePriority(.defaultLow, for: .vertical)
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        content.addSubview(hints)
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
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            centered,
            stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: Self.edgeSpacing),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: hints.topAnchor, constant: -Self.edgeSpacing),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: Self.edgeSpacing),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -Self.edgeSpacing),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentMaxWidth),
            nameLine.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            addressLine.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            hints.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hints.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hints.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        setDestination(destination)
        applyStatus()
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard KeyboardFocus.isReturn(event) else { return super.keyDown(with: event) }
        onConnect()
    }

    func setStatus(_ status: SSHHostStatus) {
        guard status != self.status else { return }
        self.status = status
        applyStatus()
    }

    func setName(_ name: String) {
        guard name != self.name else { return }
        self.name = name
        applyName()
    }

    func setDestination(_ text: String?) {
        addressLine.stringValue = text ?? ""
        addressLine.isHidden = text == nil
    }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        applyName()
        addressLine.textColor = chrome.ink(.muted)
        statusWord.textColor = chrome.ink(.subtle)
    }

    func reapplyKeymap() { applyHints() }

    func reapplyChromeLayout() {
        gutterConstraints[0].constant = ChromeMetrics.windowGutter
        gutterConstraints[1].constant = -ChromeMetrics.windowGutter
        gutterConstraints[2].constant = ChromeMetrics.topInset
        panel.reapplyChromeLayout()
    }

    func reapplyTerminalBehavior() { panel.reapplyTerminalBehavior() }

    private var isOffline: Bool { status == .offline }

    private func applyName() {
        nameLine.stringValue = name
        nameLine.textColor = Theme.current.chrome.ink(.normal)
        for button in [connectButton, connectAnywayButton] { button.setAccessibilityLabel("Connect to \(name)") }
    }

    private func applyStatus() {
        statusWord.stringValue = isOffline ? SSHHostStatus.offline.word : SSHHostStatus.online.word
        onlineDot.isHidden = isOffline
        emblem.setDimmed(isOffline)
        connectButton.isHidden = isOffline
        connectAnywayButton.isHidden = !isOffline
        applyHints()
    }

    private func applyHints() {
        let connect = HintFooter.Hint(keys: Self.returnKey, label: isOffline ? "Connect Anyway" : "Connect")
        let editKeys = CommandCatalog.spec(for: .searchSelection).shortcut
        let edit = editKeys.isEmpty ? [] : [HintFooter.Hint(keys: editKeys, label: "Edit Host")]
        hints.setHints([connect] + edit)
    }

    var nameForTesting: String { nameLine.stringValue }
    var nameFieldForTesting: NSTextField { nameLine }
    var addressFieldForTesting: NSTextField { addressLine }
    var statusForTesting: String { statusWord.stringValue }
    var showsOnlineDotForTesting: Bool { !onlineDot.isHidden }
    var onlineDotForTesting: StateDot { onlineDot }
    var destinationForTesting: String? { addressLine.isHidden ? nil : addressLine.stringValue }
    var emblemForTesting: HostEmblemView { emblem }
    var detachedForTesting: [NSView] { stack.detachedViews }
    var panelForTesting: PanelHostView { panel }
    var actionButtonForTesting: AppButton { isOffline ? connectAnywayButton : connectButton }
    var hintsForTesting: [HintFooter.Hint] { hints.hints }
}
