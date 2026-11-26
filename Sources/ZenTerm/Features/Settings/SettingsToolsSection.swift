import AppKit

final class SettingsToolsSection: SettingsSection {
    var navTitle: String { "Tools" }
    var onExitToNav: (() -> Void)?
    var onEditFloat: ((ToolFloat?) -> Void)?
    var onReorder: (([ToolFloat]) -> Void)?

    private var rows: [ToolFloatRow] = []
    private var addButton: AppButton?
    private weak var reorderHint: NSTextField?
    private weak var droppedFloatNotice: NSTextField?
    private var rowsStack: NSStackView?
    private var fillSlide: RowFillSlide?
    var fillSlideForTesting: RowFillSlide? { fillSlide }
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
        stack.alignment = .centerX
        stack.spacing = ChromeMetrics.Spacing.s2
        stack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack = stack
        fillSlide = RowFillSlide(host: stack)

        let button = AppButton(title: "＋ Add tool float", variant: .muted)
        button.isKeyboardFocusable = true
        button.onArrowUp = { [weak self] in self?.moveFocus(from: self?.addButton, delta: -1) }
        button.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        button.onTab = { [weak self] in self?.moveTab(from: self?.addButton, delta: 1) }
        button.onBacktab = { [weak self] in self?.moveTab(from: self?.addButton, delta: -1) }
        button.onTap = { [weak self] in self?.onEditFloat?(nil) }
        addButton = button

        populateRows()
        return SettingsDetail.scroll(for: stack, outset: SettingsDetail.listOutset)
    }

    func detailStops() -> [NSView] { rows + [addButton].compactMap { $0 } }

    func reapplyTheme() {
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

        let caption = SectionCaption("Tool floats")

        let floats = GeneralConfig.current.floats
        let header = SettingsDetail.headerRow(
            caption: caption, hint: floats.count > 1 ? makeReorderHint() : nil)
        stack.addArrangedSubview(header)
        SettingsDetail.pinToListContent(header, in: stack)

        let dropped = droppedFloatMessages()
        if !dropped.isEmpty {
            let notice = NSTextField(wrappingLabelWithString: dropped.joined(separator: "\n"))
            notice.font = ChromeType.font(.caption, weight: .medium)
            notice.textColor = Theme.current.chrome.warning.nsColor
            droppedFloatNotice = notice
            stack.addArrangedSubview(notice)
            SettingsDetail.pinToListContent(notice, in: stack)
            stack.setCustomSpacing(ChromeMetrics.Spacing.s10, after: notice)
        }

        if floats.isEmpty {
            let hint = EmptyStateLabel("No tool floats yet. Add one to get a toolbar button and a shortcut.")
            stack.addArrangedSubview(hint)
            SettingsDetail.pinToListContent(hint, in: stack)
        } else {
            for float in floats {
                let row = ToolFloatRow(float: float)
                row.showMessage(fieldDiagnosticMessages(for: float.id))
                row.onChoose = { [weak self, weak row] in row.map { self?.onEditFloat?($0.float) } }
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
                fillSlide?.adopt(row)
            }
        }
        stack.setCustomSpacing(ChromeMetrics.Spacing.s10, after: header)

        let addRow = SettingsDetail.trailingRow(addButton)
        stack.addArrangedSubview(addRow)
        SettingsDetail.pinToListContent(addRow, in: stack)
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
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta, holding: fillSlide) { $0 }
    }

    private func moveTab(from view: NSView?, delta: Int) {
        guard let view else { return }
        let stops = detailStops()
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        if delta < 0, anchor == 0 {
            onExitToNav?()
            return
        }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta, wrap: true, holding: fillSlide) { $0 }
    }
}

final class ToolFloatRow: SettingsFocusRow {
    let float: ToolFloat
    private let messageLabel = FormErrorLabel()

    init(float: ToolFloat) {
        self.float = float
        super.init(Self.content(for: float))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyKeymap() {
        render(Self.content(for: float))
    }

    private static func content(for float: ToolFloat) -> Content {
        let shortcut = CommandCatalog.spec(for: .toggleToolFloat(float.id)).shortcut
        return Content(
            title: float.title, subtitle: float.command, note: shortcut.isEmpty ? "Not set" : nil,
            leading: .symbol(float.icon), trailing: shortcut.isEmpty ? nil : .keycap(shortcut))
    }

    func showMessage(_ text: String?) {
        guard let text else {
            messageLabel.clear()
            footnote = nil
            return
        }
        messageLabel.show(text, tone: .warning)
        footnote = messageLabel
    }

    var renderedMessageForTesting: String? {
        footnote == nil ? nil : messageLabel.stringValue
    }

    var renderedShortcutForTesting: String {
        shortcutForTesting.isEmpty ? content.note ?? "" : shortcutForTesting
    }
}
