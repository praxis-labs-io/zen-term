import AppKit

/// The Tools settings section: the configured tool floats, with add / edit / remove. Each float is a
/// focusable `ToolFloatRow` — Return / click opens the edit form, Backspace removes it, Up/Down move
/// between rows, Left exits to the nav, Esc closes the card. A trailing "Add tool float" button opens
/// a blank form. Add / edit route out through `onEditFloat` (the host presents `ToolFloatFormOverlay`
/// and writes on submit); remove writes inline via `ConfigWriter` + `AppConfig.reload()`, so the dock
/// button, ⌘P entry, and keybind update with no restart.
final class SettingsToolsSection: SettingsSection {
    var navTitle: String { "Tools" }
    var onExitToNav: (() -> Void)?
    var onClose: (() -> Void)?
    /// Set by the host: open the add / edit form. `nil` adds a new float; a value edits that one.
    var onEditFloat: ((ToolFloat?) -> Void)?

    private var rows: [ToolFloatRow] = []
    private let addButton = AppButton(title: "＋ Add tool float", variant: .muted)
    /// Retained so `reapplyTheme()` / `rebuildRows()` can reach them in place.
    private let caption = SettingsDetail.groupCaption("Tool floats")
    private let emptyHint = NSTextField(labelWithString: "")
    private var rowsStack: NSStackView?
    private weak var detailScroll: NSScrollView?

    func makeDetailView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack = stack

        emptyHint.font = .systemFont(ofSize: 12)
        emptyHint.textColor = Theme.current.chrome.ink(alpha: 0.5)
        emptyHint.stringValue = "No tool floats yet. Add one to get a dock button and a shortcut."
        emptyHint.lineBreakMode = .byWordWrapping
        emptyHint.maximumNumberOfLines = 0

        addButton.isKeyboardFocusable = true
        addButton.onArrowUp = { [weak self] in self?.moveFocus(from: self?.addButton, delta: -1) }
        addButton.onArrowLeft = { [weak self] in self?.onExitToNav?() }
        addButton.onEsc = { [weak self] in self?.onClose?() }
        addButton.onTap = { [weak self] in self?.onEditFloat?(nil) }

        populateRows()

        let scroll = SettingsDetail.scroll(for: stack)
        detailScroll = scroll
        return scroll
    }

    func detailStops() -> [NSView] { rows + [addButton] }

    func reapplyTheme() {
        caption.textColor = Theme.current.chrome.ink(alpha: 0.4)
        emptyHint.textColor = Theme.current.chrome.ink(alpha: 0.5)
        rows.forEach { $0.reapplyTheme() }
        addButton.reapplyTheme()
    }

    // MARK: rows

    /// (Re)fill the rows stack from the live config — used on first build and after a remove, so the
    /// list reflects the current floats without the card rebuilding the whole detail view.
    private func populateRows() {
        guard let stack = rowsStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []

        stack.addArrangedSubview(caption)
        caption.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let floats = GeneralConfig.current.floats
        if floats.isEmpty {
            stack.addArrangedSubview(emptyHint)
            emptyHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.setCustomSpacing(10, after: caption)
        } else {
            for float in floats {
                let row = ToolFloatRow(float: float)
                row.onActivate = { [weak self, weak row] in row.map { self?.onEditFloat?($0.float) } }
                row.onRemove = { [weak self, weak row] in row.map { self?.remove($0) } }
                row.onArrowUp = { [weak self, weak row] in self?.moveFocus(from: row, delta: -1) }
                row.onArrowDown = { [weak self, weak row] in self?.moveFocus(from: row, delta: 1) }
                row.onExitToNav = { [weak self] in self?.onExitToNav?() }
                row.onEsc = { [weak self] in self?.onClose?() }
                rows.append(row)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            stack.setCustomSpacing(10, after: caption)
        }

        let addRow = SettingsDetail.trailingRow(addButton)
        stack.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
    }

    /// Remove a float: write it out, reload the live config, then rebuild the list. On a write
    /// failure the row stays and shows why. Focus lands on the add button (the removed row is gone).
    private func remove(_ row: ToolFloatRow) {
        do {
            try ConfigWriter.apply(floatRemovals: [row.float.id])
        } catch {
            row.showMessage("Couldn’t write config: \(error.localizedDescription)")
            return
        }
        AppConfig.reload()
        populateRows()
        detailScroll?.window?.makeFirstResponder(addButton)
    }

    private func moveFocus(from view: NSView?, delta: Int) {
        guard let view else { return }
        let stops = rows + [addButton]
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta) { $0 }
    }
}

/// One Tools row: a float's icon, title, an id · command subtitle, and its shortcut keycap, with an
/// inline remove button. The whole row is one focus stop — Return / click edits, Backspace removes,
/// Up/Down move rows, Left exits to nav, Esc closes. An inline message under the row carries a write
/// error. Mirrors `KeybindRow`.
final class ToolFloatRow: NSView {
    let float: ToolFloat
    var onActivate: (() -> Void)?
    var onRemove: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onExitToNav: (() -> Void)?
    var onEsc: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let keycap: KeycapView
    private let removeButton = AppButton(title: "✕", variant: .secondary)
    private let messageLabel = NSTextField(labelWithString: "")
    private var isFocused = false { didSet { restyle() } }

    init(float: ToolFloat) {
        self.float = float
        titleLabel = NSTextField(labelWithString: float.title)
        subtitleLabel = NSTextField(labelWithString: "\(float.id) · \(float.command)")
        keycap = KeycapView(shortcut: float.shortcut)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        iconView.image = IconCatalog.image(float.icon)
        iconView.contentTintColor = Theme.current.chrome.ink(alpha: 0.75)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = Theme.current.chrome.ink(alpha: 0.5)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        removeButton.setContentHuggingPriority(.required, for: .horizontal)
        removeButton.onTap = { [weak self] in self?.onRemove?() }
        let controls = NSStackView(views: [iconView, labels, spacer, keycap, removeButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10

        messageLabel.font = .systemFont(ofSize: 11, weight: .medium)
        messageLabel.textColor = Theme.current.chrome.destructive.nsColor
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
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = (text == nil)
    }

    func reapplyTheme() {
        iconView.contentTintColor = Theme.current.chrome.ink(alpha: 0.75)
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        subtitleLabel.textColor = Theme.current.chrome.ink(alpha: 0.5)
        messageLabel.textColor = Theme.current.chrome.destructive.nsColor
        keycap.reapplyTheme()
        removeButton.reapplyTheme()
        restyle()
    }

    // MARK: focus + keyboard

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }
    override func drawFocusRingMask() {}

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .activate: onActivate?()
        case .delete: onRemove?()
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .left: onExitToNav?()
        case .escape: onEsc?()
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
        layer?.backgroundColor = isFocused ? chrome.ink(alpha: 0.10).cgColor : nil
        layer?.borderWidth = isFocused ? 1.5 : 0
        layer?.borderColor = isFocused ? chrome.accent.nsColor.cgColor : nil
    }
}
