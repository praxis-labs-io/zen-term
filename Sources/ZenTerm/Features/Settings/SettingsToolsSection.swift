import AppKit

final class SettingsToolsSection: SettingsSection {
    var navTitle: String { "Tools" }
    var onExitToNav: (() -> Void)?
    var onEditFloat: ((ToolFloat?) -> Void)?
    var onReorder: (([ToolFloat]) -> Void)?

    private var rows: [ToolFloatRow] = []
    private var addButton: AppButton?
    private weak var caption: NSTextField?
    private weak var emptyHint: NSTextField?
    private weak var reorderHint: NSTextField?
    private weak var droppedFloatNotice: NSTextField?
    private var rowsStack: NSStackView?
    private var configObserver: NSObjectProtocol?

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .configDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard ConfigChange.from(note).contains(.keymap) else { return }
            MainActor.assumeIsolated { self?.rows.forEach { $0.reapplyKeymap() } }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    func makeDetailView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ChromeMetrics.Spacing.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack = stack

        let button = AppButton(title: "＋ Add tool float", variant: .muted)
        button.isKeyboardFocusable = true
        button.onArrowUp = { [weak self] in self?.moveFocus(from: self?.addButton, delta: -1) }
        button.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        button.onTab = { [weak self] in self?.moveTab(from: self?.addButton, delta: 1) }
        button.onBacktab = { [weak self] in self?.moveTab(from: self?.addButton, delta: -1) }
        button.onTap = { [weak self] in self?.onEditFloat?(nil) }
        addButton = button

        populateRows()
        return SettingsDetail.scroll(for: stack)
    }

    func detailStops() -> [NSView] { rows + [addButton].compactMap { $0 } }

    func reapplyTheme() {
        caption?.textColor = Theme.current.chrome.ink(.muted)
        emptyHint?.textColor = Theme.current.chrome.ink(.muted)
        reorderHint?.textColor = Theme.current.chrome.ink(.faint)
        droppedFloatNotice?.textColor = Theme.current.chrome.warning.nsColor
    }

    private func droppedFloatMessages() -> [String] {
        GeneralConfig.current.configDiagnostics.compactMap {
            if case .toolFloat = $0.scope { return $0.message }
            return nil
        }
    }

    private func fieldDiagnosticMessages(for id: String) -> String? {
        let messages = GeneralConfig.current.configDiagnostics.compactMap { diagnostic -> String? in
            if case .toolFloatField(let fieldID, _) = diagnostic.scope, fieldID == id {
                return diagnostic.message
            }
            return nil
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private func makeReorderHint() -> NSTextField {
        let hint = SettingsDetail.reorderHint()
        reorderHint = hint
        return hint
    }

    private func populateRows() {
        guard let stack = rowsStack, let addButton else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []

        let caption = SettingsDetail.groupCaption("Tool floats")
        self.caption = caption

        let floats = GeneralConfig.current.floats
        let header = SettingsDetail.headerRow(
            caption: caption, hint: floats.count > 1 ? makeReorderHint() : nil)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let dropped = droppedFloatMessages()
        if !dropped.isEmpty {
            let notice = NSTextField(wrappingLabelWithString: dropped.joined(separator: "\n"))
            notice.font = ChromeType.font(.caption, weight: .medium)
            notice.textColor = Theme.current.chrome.warning.nsColor
            droppedFloatNotice = notice
            stack.addArrangedSubview(notice)
            notice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.setCustomSpacing(ChromeMetrics.Spacing.s10, after: notice)
        }

        if floats.isEmpty {
            let hint = NSTextField(
                labelWithString: "No tool floats yet. Add one to get a toolbar button and a shortcut.")
            hint.font = ChromeType.font(.small)
            hint.textColor = Theme.current.chrome.ink(.muted)
            hint.lineBreakMode = .byWordWrapping
            hint.maximumNumberOfLines = 0
            emptyHint = hint
            stack.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else {
            for float in floats {
                let row = ToolFloatRow(float: float)
                row.showMessage(fieldDiagnosticMessages(for: float.id))
                row.onActivate = { [weak self, weak row] in row.map { self?.onEditFloat?($0.float) } }
                row.onArrowUp = { [weak self, weak row] in self?.moveFocus(from: row, delta: -1) }
                row.onArrowDown = { [weak self, weak row] in self?.moveFocus(from: row, delta: 1) }
                row.onMoveUp = { [weak self, weak row] in self?.move(row, delta: -1) }
                row.onMoveDown = { [weak self, weak row] in self?.move(row, delta: 1) }
                row.onTab = { [weak self, weak row] in self?.moveTab(from: row, delta: 1) }
                row.onBacktab = { [weak self, weak row] in self?.moveTab(from: row, delta: -1) }
                row.onExitToNav = { [weak self] in self?.onExitToNav?() }
                rows.append(row)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        stack.setCustomSpacing(ChromeMetrics.Spacing.s10, after: header)

        let addRow = SettingsDetail.trailingRow(addButton)
        stack.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(
            ChromeMetrics.Spacing.s16, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
    }

    // Deferred a runloop turn: the rebuild frees this row while its `keyDown` is still on the stack.
    private func move(_ row: ToolFloatRow?, delta: Int) {
        guard let row else { return }
        var floats = GeneralConfig.current.floats
        guard let from = floats.firstIndex(where: { $0.id == row.float.id }) else { return }
        let to = from + delta
        guard floats.indices.contains(to) else { return }
        floats.swapAt(from, to)

        let movedID = row.float.id
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onReorder?(floats)
            self.populateRows()
            guard let moved = self.rows.first(where: { $0.float.id == movedID }) else { return }
            moved.window?.makeFirstResponder(moved)
            KeyboardFocus.reveal(moved, among: self.detailStops())
        }
    }

    private func moveFocus(from view: NSView?, delta: Int) {
        guard let view else { return }
        let stops = detailStops()
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta) { $0 }
    }

    private func moveTab(from view: NSView?, delta: Int) {
        guard let view else { return }
        let stops = detailStops()
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        if delta < 0, anchor == 0 {
            onExitToNav?()
            return
        }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta, wrap: true) { $0 }
    }
}

final class ToolFloatRow: SettingsFocusRow {
    let float: ToolFloat
    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private var shortcutView: NSView
    private let controls = NSStackView()
    private let messageLabel = NSTextField(labelWithString: "")

    init(float: ToolFloat) {
        self.float = float
        titleLabel = NSTextField(labelWithString: float.title)
        subtitleLabel = NSTextField(labelWithString: float.command)
        shortcutView = Self.makeShortcutView(for: float)

        super.init()

        iconView.image = IconCatalog.image(float.icon)
        iconView.contentTintColor = Theme.current.chrome.ink(.subtle)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = ChromeType.font(.body)
        titleLabel.textColor = Theme.current.chrome.ink(.normal)
        subtitleLabel.font = ChromeType.font(.caption)
        subtitleLabel.textColor = Theme.current.chrome.ink(.muted)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = ChromeMetrics.Spacing.s2
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        [iconView, labels, spacer, shortcutView].forEach(controls.addArrangedSubview)
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = ChromeMetrics.Spacing.s10

        messageLabel.font = ChromeType.font(.caption, weight: .medium)
        messageLabel.textColor = Theme.current.chrome.warning.nsColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.isHidden = true

        let stack = NSStackView(views: [controls, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ChromeMetrics.Spacing.s2
        pin(stack)
        NSLayoutConstraint.activate([
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func reapplyTheme() {
        iconView.contentTintColor = Theme.current.chrome.ink(.subtle)
        titleLabel.textColor = Theme.current.chrome.ink(.normal)
        subtitleLabel.textColor = Theme.current.chrome.ink(.muted)
        messageLabel.textColor = Theme.current.chrome.warning.nsColor
        (shortcutView as? NSTextField)?.textColor = Self.unsetInk
        super.reapplyTheme()
    }

    func reapplyKeymap() {
        shortcutView.removeFromSuperview()
        shortcutView = Self.makeShortcutView(for: float)
        controls.addArrangedSubview(shortcutView)
    }

    private static func makeShortcutView(for float: ToolFloat) -> NSView {
        let shortcut = CommandCatalog.spec(for: .toggleToolFloat(float.id)).shortcut
        return shortcut.isEmpty ? unsetLabel() : KeycapView(shortcut: shortcut)
    }

    private static var unsetInk: NSColor { Theme.current.chrome.ink(.muted) }

    private static func unsetLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "Not set")
        label.font = ChromeType.font(.small)
        label.textColor = unsetInk
        return label
    }

    func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = (text == nil)
    }

    var renderedMessageForTesting: String? {
        messageLabel.isHidden ? nil : messageLabel.stringValue
    }

    var renderedShortcutForTesting: String {
        (shortcutView as? KeycapView)?.shortcut ?? (shortcutView as? NSTextField)?.stringValue ?? ""
    }
}
