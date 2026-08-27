import AppKit

/// The Tools settings section: the configured tool floats, with add / edit / reorder. Each float is a
/// focusable `ToolFloatRow` — Return / click opens the edit form (delete lives there), Up/Down move
/// between rows, ⌥Up/⌥Down move the float itself (the order the dock, ⌘P, and this list all read),
/// Left exits to the nav, Esc closes the card. A trailing "Add tool float" button opens a blank
/// form. Add / edit route out through `onEditFloat`; the host presents `ToolFloatFormOverlay`, which
/// writes on submit / delete and reloads, so the dock button, ⌘P entry, and keybind update with no
/// restart.
final class SettingsToolsSection: SettingsSection {
    var navTitle: String { "Tools" }
    var onExitToNav: (() -> Void)?
    /// Set by the host: open the add / edit form. `nil` adds a new float; a value edits that one.
    var onEditFloat: ((ToolFloat?) -> Void)?
    /// Set by the host: persist a new float order. The array order *is* the intent — the host stamps
    /// `order:` from it and reloads, and this section then rebuilds from the reloaded config, so a
    /// reorder follows the same write → reload → rebuild path as an add / edit / delete.
    var onReorder: (([ToolFloat]) -> Void)?

    private var rows: [ToolFloatRow] = []
    private let addButton = AppButton(title: "＋ Add tool float", variant: .muted)
    /// Rebuilt fresh by `populateRows` on each `makeDetailView` (the card rebuilds a section's detail
    /// on every switch), so their width constraints never accumulate on a retained view. Weak refs
    /// just let `reapplyTheme` recolor whichever pair is currently mounted.
    private weak var caption: NSTextField?
    private weak var emptyHint: NSTextField?
    private weak var reorderHint: NSTextField?
    /// The dropped-`float`-line notice, when the config has any. A dropped float never becomes
    /// a row, so this top-of-section note is its only in-Settings home.
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
        reorderHint?.textColor = Theme.current.chrome.ink(.muted)
        droppedFloatNotice?.textColor = Theme.current.chrome.warning.nsColor
        rows.forEach { $0.reapplyTheme() }
        addButton.reapplyTheme()
    }

    /// The `.message` of every dropped-`float`-line diagnostic in the live config — what the
    /// top-of-section notice lists, since a dropped float has no row of its own.
    private func droppedFloatMessages() -> [String] {
        GeneralConfig.current.configDiagnostics.compactMap {
            if case .toolFloat = $0.scope { return $0.message }
            return nil
        }
    }

    /// The sub-field diagnostics for one surviving float (matched by id), joined for its row — a float
    /// with a bad `width:` and a bad `order:` shows both. Nil when the float is clean.
    private func fieldDiagnosticMessages(for id: String) -> String? {
        let messages = GeneralConfig.current.configDiagnostics.compactMap { diagnostic -> String? in
            if case .toolFloatField(let fieldID, _) = diagnostic.scope, fieldID == id {
                return diagnostic.message
            }
            return nil
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    // MARK: rows

    private func makeReorderHint() -> NSTextField {
        let hint = SettingsDetail.reorderHint()
        reorderHint = hint
        return hint
    }

    /// Fill the rows stack from the live config. The list refreshes after an add / edit / delete
    /// because the form hands back to a freshly-built Settings → Tools (no in-place mutation here).
    private func populateRows() {
        guard let stack = rowsStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []

        let caption = SettingsDetail.groupCaption("Tool floats")
        self.caption = caption

        let floats = GeneralConfig.current.floats
        // ⌥↑/⌥↓ is invisible without this — nothing else on the row says a float can move. Only shown
        // with something to reorder, so it never advertises a keystroke that would do nothing.
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
            stack.setCustomSpacing(10, after: notice)  // header→notice spacing is set below, uniformly
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
                row.showMessage(fieldDiagnosticMessages(for: float.id))  // a bad width:/order:/persist:
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

    /// Move a float one slot and persist the whole list in its new order, then rebuild and keep focus
    /// on the row that moved so ⌥↓⌥↓ walks a float down without re-finding it.
    ///
    /// Deferred to the next runloop turn because the rebuild *frees this row*: `populateRows` drops
    /// the last reference to it while its own `keyDown` is still on the stack. (The edit path gets away
    /// with a synchronous callback only because modal teardown is animated.)
    private func move(_ row: ToolFloatRow?, delta: Int) {
        guard let row else { return }
        var floats = GeneralConfig.current.floats
        guard let from = floats.firstIndex(where: { $0.id == row.float.id }) else { return }
        let to = from + delta
        guard floats.indices.contains(to) else { return }  // already at an end
        floats.swapAt(from, to)

        let movedID = row.float.id
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onReorder?(floats)
            // Unconditional: on a failed write the config is unchanged, so the rebuild simply puts the
            // row back where it was rather than leaving the list lying about the file.
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

    /// Tab traversal, which differs from the arrows at the ends: Tab wraps from the last stop back
    /// to the first, and Shift-Tab retreats one stop, exiting to the nav only from the first —
    /// mirroring how Left exits.
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

/// One Tools row: a float's icon, title, its command, and its shortcut keycap. The whole row is one
/// focus stop — Return / click opens the edit form (where delete lives), Up/Down (and Tab/Shift-Tab)
/// move rows, ⌥Up/⌥Down reorder the float itself, Left exits to nav. Mirrors `KeybindRow`.
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
    /// The trailing shortcut cell: a keycap, or a muted "Not set" when the float has none. Reads
    /// like the Keybinds section's unbound chip rather than drawing an empty cap.
    private let shortcutView: NSView
    /// A surviving float's sub-field diagnostic: a bad `width:`/`order:`/`persist:` shows here,
    /// in warning tone, since the float still works and has this row.
    private let messageLabel = NSTextField(labelWithString: "")
    private var isFocused = false { didSet { restyle() } }

    init(float: ToolFloat) {
        self.float = float
        titleLabel = NSTextField(labelWithString: float.title)
        subtitleLabel = NSTextField(labelWithString: float.command)
        // Resolved from the live keymap, not from `float.toggle`, which is the raw config value.
        // A `key:` the assembler refused (a menu chord) is still on the float, so drawing it here
        // would advertise a shortcut that does something else entirely. The dock and the palette
        // already resolve this way.
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
            // Pin the wrapping message to the row width too — the `.leading` stack won't stretch it, so
            // without this the multi-line label sizes to its full intrinsic width and overflows the row.
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

    /// Show (or clear, with nil) the row's inline sub-field diagnostic.
    func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = (text == nil)
    }

    /// Test hook: the inline message as actually rendered — nil when the label is hidden, so a test
    /// can't pass while the row shows nothing.
    var renderedMessageForTesting: String? {
        messageLabel.isHidden ? nil : messageLabel.stringValue
    }

    /// Test hook: what the trailing cell draws — the keycap's glyph, or the unset placeholder's
    /// text. Reads the mounted view, so a test can't pass while the row draws an empty cap.
    var renderedShortcutForTesting: String {
        (shortcutView as? KeycapView)?.shortcut ?? (shortcutView as? NSTextField)?.stringValue ?? ""
    }

    // MARK: focus + keyboard

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }
    override func drawFocusRingMask() {}

    override func keyDown(with event: NSEvent) {
        let key = KeyboardFocus.key(for: event)
        // ⌥Up/⌥Down reorder the float instead of moving focus. `KeyboardFocus.key(for:)` decodes the
        // keyCode alone, so ⌥↑ arrives indistinguishable from a plain `.up` — the modifier check has
        // to happen here.
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
        layer?.backgroundColor = isFocused ? chrome.fill(alpha: 0.10).cgColor : nil
        layer?.borderWidth = isFocused ? 1.5 : 0
        layer?.borderColor = isFocused ? chrome.accent.nsColor.cgColor : nil
    }
}
