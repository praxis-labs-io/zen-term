import AppKit
import ControlProtocol

// The canvas for an SSH host that isn't connected, and for its first login's questions while that runs behind it.
final class HostConnectView: NSView, ThemeReapplying {
    struct Login: Equatable {
        var question: SSHLoginQuestion?
        var output: [String]
    }

    static let outputLineCount = 3
    private static let edgeSpacing = ChromeMetrics.Spacing.s12
    private static let emblemToName = ChromeMetrics.Spacing.s24
    private static let nameToAddress = ChromeMetrics.Spacing.s6
    private static let addressToStatus = ChromeMetrics.Spacing.s12
    private static let statusToButton = ChromeMetrics.Spacing.s24
    private static let contentMaxWidth: CGFloat = 420
    private static let promptToAnswer = ChromeMetrics.Spacing.s8
    private static let answerToRetry = ChromeMetrics.Spacing.s6
    private static let actionsToOutput = ChromeMetrics.Spacing.s24
    private static let answerWidth: CGFloat = 260
    private static let retryMessage = "That didn't work. Try again."

    // A short window drops the emblem first, so the action never leaves the screen.
    private static let emblemVisibility = NSStackView.VisibilityPriority(rawValue: 500)

    let host: SSHHostID
    private var name: String
    private let onConnect: () -> Void
    private let onCancel: () -> Void
    private let onAnswer: (AskpassAnswer) -> Void
    private let onTrust: () -> Void
    private var login: Login?
    private var status: SSHHostStatus
    private let emblem: HostEmblemView
    private let nameLine = NSTextField(labelWithString: "")
    private let addressLine = NSTextField(labelWithString: "")
    private let onlineDot = StateDot(.online)
    private let statusWord = NSTextField(labelWithString: "")
    private let statusLine = NSStackView()
    private let connectButton: AppButton
    private let connectAnywayButton: AppButton
    private let promptLabel = NSTextField(wrappingLabelWithString: "")
    private let fingerprintLine = NSTextField(labelWithString: "")
    private let answerField = FieldBox(placeholder: "", hidesText: true)
    private let retryLine = FormErrorLabel(maximumLines: 1)
    private let answerBox = NSStackView()
    private let trustButton: AppButton
    private let cancelButton: AppButton
    private let loginActions = NSStackView()
    private let outputLines = (0..<HostConnectView.outputLineCount).map { _ in NSTextField(labelWithString: "") }
    private let output = NSStackView()
    private let stack = NSStackView()
    private let panel: PanelHostView
    private let content = NSView()
    private var gutterConstraints: [NSLayoutConstraint] = []

    init(
        host: SSHHostID, name: String, status: SSHHostStatus, destination: String?, onConnect: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}, onAnswer: @escaping (AskpassAnswer) -> Void = { _ in },
        onTrust: @escaping () -> Void = {}, onFocusRequest: @escaping () -> Void
    ) {
        self.host = host
        self.name = name
        self.status = status
        self.onConnect = onConnect
        self.onCancel = onCancel
        self.onAnswer = onAnswer
        self.onTrust = onTrust
        trustButton = AppButton(title: "Trust", variant: .primary, onTap: onTrust)
        cancelButton = AppButton(title: "Cancel", variant: .secondary, onTap: onCancel)
        emblem = HostEmblemView(host: host)
        connectButton = AppButton(
            title: "Connect", variant: .primary, onTap: onConnect)
        connectAnywayButton = AppButton(
            title: "Connect Anyway", variant: .muted, onTap: onConnect)
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
        configureLoginViews()

        [
            emblem, nameLine, addressLine, statusLine, promptLabel, fingerprintLine, answerBox, connectButton,
            connectAnywayButton, loginActions, output,
        ].forEach(stack.addArrangedSubview)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.detachesHiddenViews = true
        stack.setCustomSpacing(Self.emblemToName, after: emblem)
        stack.setCustomSpacing(Self.nameToAddress, after: nameLine)
        stack.setCustomSpacing(Self.addressToStatus, after: addressLine)
        stack.setCustomSpacing(Self.statusToButton, after: statusLine)
        stack.setCustomSpacing(Self.promptToAnswer, after: promptLabel)
        stack.setCustomSpacing(Self.statusToButton, after: fingerprintLine)
        stack.setCustomSpacing(Self.statusToButton, after: answerBox)
        stack.setCustomSpacing(Self.actionsToOutput, after: loginActions)
        stack.setVisibilityPriority(Self.emblemVisibility, for: emblem)
        stack.setClippingResistancePriority(.defaultLow, for: .vertical)
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
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
        let centered = stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            centered,
            stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: Self.edgeSpacing),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -Self.edgeSpacing),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: Self.edgeSpacing),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -Self.edgeSpacing),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentMaxWidth),
            nameLine.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            addressLine.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            promptLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            fingerprintLine.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            answerField.widthAnchor.constraint(equalToConstant: Self.answerWidth),
            output.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        setDestination(destination)
        applyStatus()
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if KeyboardFocus.isReturn(event) {
            if login == nil { return onConnect() }
            if isAskingHostKey { onTrust() }
            return
        }
        guard login != nil, KeyboardFocus.key(for: event) == .escape else { return super.keyDown(with: event) }
        onCancel()
    }

    // ssh waiting on an answer puts focus in its field.
    var focusTarget: NSView { answerBox.isHidden ? self : answerField.field }

    func setLogin(_ login: Login?) {
        guard login != self.login else { return }
        let asked = login?.question != self.login?.question
        let heldFocus = holdsFocus
        self.login = login
        if asked { answerField.setText("") }
        applyStatus()
        if heldFocus, asked { window?.makeFirstResponder(focusTarget) }
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
        promptLabel.textColor = chrome.ink(.subtle)
        fingerprintLine.textColor = chrome.ink(.muted)
        for line in outputLines { line.textColor = chrome.ink(.muted) }
        retryLine.reapplyTheme()
        answerField.reapplyTheme()
    }

    func reapplyChromeLayout() {
        gutterConstraints[0].constant = ChromeMetrics.windowGutter
        gutterConstraints[1].constant = -ChromeMetrics.windowGutter
        gutterConstraints[2].constant = ChromeMetrics.topInset
        panel.reapplyChromeLayout()
    }

    func reapplyTerminalBehavior() { panel.reapplyTerminalBehavior() }

    private var isOffline: Bool { status == .offline }

    private var isAskingHostKey: Bool {
        if case .hostKey = login?.question?.prompt { return true }
        return false
    }

    private var secretLabel: String? {
        if case .secret(let label) = login?.question?.prompt { return label }
        return nil
    }

    private var holdsFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    private func configureLoginViews() {
        promptLabel.font = ChromeType.font(.small)
        promptLabel.alignment = .center
        promptLabel.preferredMaxLayoutWidth = Self.contentMaxWidth
        promptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fingerprintLine.font = ChromeType.font(.small, face: .mono)
        fingerprintLine.alignment = .center
        fingerprintLine.lineBreakMode = .byTruncatingMiddle
        fingerprintLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        answerField.onEnter = { [weak self] in self?.submitAnswer() }
        answerField.onEscape = { [weak self] in self?.onCancel() }
        answerBox.orientation = .vertical
        answerBox.alignment = .centerX
        answerBox.spacing = Self.answerToRetry
        answerBox.detachesHiddenViews = true
        [answerField, retryLine].forEach(answerBox.addArrangedSubview)
        loginActions.orientation = .horizontal
        loginActions.spacing = ChromeMetrics.Spacing.s8
        loginActions.detachesHiddenViews = true
        [trustButton, cancelButton].forEach(loginActions.addArrangedSubview)
        output.orientation = .vertical
        output.alignment = .centerX
        output.spacing = 0
        output.detachesHiddenViews = true
        for line in outputLines {
            line.font = ChromeType.font(.small, face: .mono)
            line.alignment = .center
            line.lineBreakMode = .byTruncatingTail
            line.maximumNumberOfLines = 1
            line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            output.addArrangedSubview(line)
        }
    }

    private func submitAnswer() {
        guard secretLabel != nil else { return }
        let answer = AskpassAnswer(answerField.text)
        answerField.setText("")
        onAnswer(answer)
    }

    private func applyName() {
        nameLine.stringValue = name
        nameLine.textColor = Theme.current.chrome.ink(.normal)
        for button in [connectButton, connectAnywayButton] { button.setAccessibilityLabel("Connect to \(name)") }
    }

    private func applyStatus() {
        let connecting = login != nil
        statusWord.stringValue =
            connecting ? "Connecting…" : isOffline ? SSHHostStatus.offline.word : SSHHostStatus.online.word
        statusLine.isHidden = login?.question != nil
        onlineDot.isHidden = isOffline || connecting
        emblem.setDimmed(isOffline && !connecting)
        connectButton.isHidden = isOffline || connecting
        connectAnywayButton.isHidden = !isOffline || connecting
        loginActions.isHidden = !connecting
        trustButton.isHidden = !isAskingHostKey
        applyQuestion()
        let lines = login?.output ?? []
        for (index, line) in outputLines.enumerated() {
            line.stringValue = index < lines.count ? lines[index] : ""
            line.isHidden = index >= lines.count
        }
        output.isHidden = lines.isEmpty
    }

    private func applyQuestion() {
        let fingerprint: String?
        if case .hostKey(let value) = login?.question?.prompt { fingerprint = value } else { fingerprint = nil }
        promptLabel.stringValue = secretLabel ?? (isAskingHostKey ? "New host key" : "")
        promptLabel.isHidden = login?.question == nil
        fingerprintLine.stringValue = fingerprint ?? ""
        fingerprintLine.isHidden = fingerprint == nil
        answerBox.isHidden = secretLabel == nil
        answerField.field.setAccessibilityLabel(secretLabel)
        if secretLabel != nil, login?.question?.isRetry == true {
            retryLine.show(Self.retryMessage)
        } else {
            retryLine.clear()
        }
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
    var promptForTesting: String? { promptLabel.isHidden ? nil : promptLabel.stringValue }
    var fingerprintForTesting: String? { fingerprintLine.isHidden ? nil : fingerprintLine.stringValue }
    var answerFieldForTesting: FieldBox? { answerBox.isHidden ? nil : answerField }
    var retryForTesting: String? { retryLine.isHidden ? nil : retryLine.stringValue }
    var trustButtonForTesting: AppButton? { trustButton.isHidden || loginActions.isHidden ? nil : trustButton }
    var cancelButtonForTesting: AppButton? { loginActions.isHidden ? nil : cancelButton }
    var outputForTesting: [String] { output.isHidden ? [] : outputLines.filter { !$0.isHidden }.map(\.stringValue) }
}
