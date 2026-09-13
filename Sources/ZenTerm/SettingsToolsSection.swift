import AppKit

final class SettingsToolsSection: SettingsSection {
    var navTitle: String { "Tools" }
    var onExitToNav: (() -> Void)?
    var onEditFloat: ((ToolFloat?) -> Void)?
    var onReorder: (([ToolFloat]) -> Void)?

    private var rows: [ToolFloatRow] = []
    private let addButton = AppButton(title: "＋ Add tool float", variant: .muted)
    private weak var caption: NSTextField?
    private weak var emptyHint: NSTextField?
    private weak var reorderHint: NSTextField?
    private weak var droppedFloatNotice: NSTextField?
    private var rowsStack: NSStackView?

    func makeDetailView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack = stack

        addButton.isKeyboardFocusable = true
        addButton.onArrowUp = { [weak self] in self?.moveFocus(from: self?.addButton, delta: -1) }
        addButton.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        addButton.onTab = { [weak self] in self?.moveTab(from: self?.addButton, delta: 1) }
        addButton.onBacktab = { [weak self] in self?.moveTab(from: self?.addButton, delta: -1) }
        addButton.onTap = { [weak self] in self?.onEditFloat?(nil) }

        populateRows()
        return SettingsDetail.scroll(for: stack)
    }

    func detailStops() -> [NSView] { rows + [addButton] }

    func reapplyTheme() {
        caption?.textColor = Theme.current.chrome.ink(.muted)
        emptyHint?.textColor = Theme.current.chrome.ink(.muted)
        reorderHint?.textColor = Theme.current.chrome.ink(.faint)
        droppedFloatNotice?.textColor = Theme.current.chrome.warning.nsColor
        rows.forEach { $0.reapplyTheme() }
        addButton.reapplyTheme()
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
        guard let stack = rowsStack else { return }
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
            notice.font = .systemFont(ofSize: 11, weight: .medium)
            notice.textColor = Theme.current.chrome.warning.nsColor
            droppedFloatNotice = notice
            stack.addArrangedSubview(notice)
            notice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.setCustomSpacing(10, after: notice)
        }

        if floats.isEmpty {
            let hint = NSTextField(
                labelWithString: "No tool floats yet. Add one to get a toolbar button and a shortcut.")
            hint.font = .systemFont(ofSize: 12)
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
        stack.setCustomSpacing(10, after: header)

        let addRow = SettingsDetail.trailingRow(addButton)
        stack.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
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
            KeyboardFocus.reveal(moved, among: self.rows + [self.addButton])
        }
    }

    private func moveFocus(from view: NSView?, delta: Int) {
        guard let view else { return }
        let stops = rows + [addButton]
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta) { $0 }
    }

    private func moveTab(from view: NSView?, delta: Int) {
        guard let view else { return }
        let stops = rows + [addButton]
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        if delta < 0, anchor == 0 {
            onExitToNav?()
            return
        }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta, wrap: true) { $0 }
    }
}

final class ToolFloatRow: NSView {
    let float: ToolFloat
    var onActivate: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onTab: (() -> Void)?
    var onBacktab: (() -> Void)?
    var onExitToNav: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let shortcutView: NSView
    private let messageLabel = NSTextField(labelWithString: "")
    private var isFocused = false { didSet { restyle() } }

    init(float: ToolFloat) {
        self.float = float
        titleLabel = NSTextField(labelWithString: float.title)
        subtitleLabel = NSTextField(labelWithString: float.command)
        let shortcut = CommandCatalog.spec(for: .toggleToolFloat(float.id)).shortcut
        shortcutView = shortcut.isEmpty ? Self.unsetLabel() : KeycapView(shortcut: shortcut)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        iconView.image = IconCatalog.image(float.icon)
        iconView.contentTintColor = Theme.current.chrome.ink(.subtle)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = Theme.current.chrome.ink(.muted)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [iconView, labels, spacer, shortcutView])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10

        messageLabel.font = .systemFont(ofSize: 11, weight: .medium)
        messageLabel.textColor = Theme.current.chrome.warning.nsColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.isHidden = true

        let stack = NSStackView(views: [controls, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        iconView.contentTintColor = Theme.current.chrome.ink(.subtle)
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        subtitleLabel.textColor = Theme.current.chrome.ink(.muted)
        messageLabel.textColor = Theme.current.chrome.warning.nsColor
        (shortcutView as? KeycapView)?.reapplyTheme()
        (shortcutView as? NSTextField)?.textColor = Self.unsetInk
        restyle()
    }

    private static var unsetInk: NSColor { Theme.current.chrome.ink(.muted) }

    private static func unsetLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "Not set")
        label.font = .systemFont(ofSize: 12)
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

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }
    override func drawFocusRingMask() {}

    override func keyDown(with event: NSEvent) {
        let key = KeyboardFocus.key(for: event)
        if KeyboardFocus.isOptionOnly(event) {
            switch key {
            case .up: onMoveUp?(); return
            case .down: onMoveDown?(); return
            default: break
            }
        }
        switch key {
        case .activate: onActivate?()
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .left: onExitToNav?()
        case .tab(let shift) where onTab != nil || onBacktab != nil:
            shift ? onBacktab?() : onTab?()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onActivate?()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func restyle() {
        let chrome = Theme.current.chrome
        layer?.backgroundColor = isFocused ? chrome.fill(.active).cgColor : nil
        layer?.borderWidth = isFocused ? 1.5 : 0
        layer?.borderColor = isFocused ? chrome.accent.nsColor.cgColor : nil
    }
}
