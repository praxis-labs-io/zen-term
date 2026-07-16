import AppKit

/// The Tools settings section: the configured tool floats, with add / edit. Each float is a focusable
/// `ToolFloatRow` — Return / click opens the edit form (delete lives there), Up/Down move between
/// rows, Left exits to the nav, Esc closes the card. A trailing "Add tool float" button opens a blank
/// form. Add / edit route out through `onEditFloat`; the host presents `ToolFloatFormOverlay`, which
/// writes on submit / delete and reloads, so the dock button, ⌘P entry, and keybind update with no
/// restart.
final class SettingsToolsSection: SettingsSection {
    var navTitle: String { "Tools" }
    var onExitToNav: (() -> Void)?
    /// Set by the host: open the add / edit form. `nil` adds a new float; a value edits that one.
    var onEditFloat: ((ToolFloat?) -> Void)?

    private var rows: [ToolFloatRow] = []
    private let addButton = AppButton(title: "＋ Add tool float", variant: .muted)
    /// Rebuilt fresh by `populateRows` on each `makeDetailView` (the card rebuilds a section's detail
    /// on every switch), so their width constraints never accumulate on a retained view. Weak refs
    /// just let `reapplyTheme` recolor whichever pair is currently mounted.
    private weak var caption: NSTextField?
    private weak var emptyHint: NSTextField?
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
        addButton.onTap = { [weak self] in self?.onEditFloat?(nil) }

        populateRows()
        return SettingsDetail.scroll(for: stack)
    }

    func detailStops() -> [NSView] { rows + [addButton] }

    func reapplyTheme() {
        caption?.textColor = Theme.current.chrome.ink(alpha: 0.4)
        emptyHint?.textColor = Theme.current.chrome.ink(alpha: 0.5)
        rows.forEach { $0.reapplyTheme() }
        addButton.reapplyTheme()
    }

    // MARK: rows

    /// Fill the rows stack from the live config. The list refreshes after an add / edit / delete
    /// because the form hands back to a freshly-built Settings → Tools (no in-place mutation here).
    private func populateRows() {
        guard let stack = rowsStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []

        let caption = SettingsDetail.groupCaption("Tool floats")
        self.caption = caption
        stack.addArrangedSubview(caption)
        caption.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let floats = GeneralConfig.current.floats
        if floats.isEmpty {
            let hint = NSTextField(labelWithString: "No tool floats yet. Add one to get a dock button and a shortcut.")
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = Theme.current.chrome.ink(alpha: 0.5)
            hint.lineBreakMode = .byWordWrapping
            hint.maximumNumberOfLines = 0
            emptyHint = hint
            stack.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else {
            for float in floats {
                let row = ToolFloatRow(float: float)
                row.onActivate = { [weak self, weak row] in row.map { self?.onEditFloat?($0.float) } }
                row.onArrowUp = { [weak self, weak row] in self?.moveFocus(from: row, delta: -1) }
                row.onArrowDown = { [weak self, weak row] in self?.moveFocus(from: row, delta: 1) }
                row.onExitToNav = { [weak self] in self?.onExitToNav?() }
                rows.append(row)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        stack.setCustomSpacing(10, after: caption)

        let addRow = SettingsDetail.trailingRow(addButton)
        stack.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
    }

    private func moveFocus(from view: NSView?, delta: Int) {
        guard let view else { return }
        let stops = rows + [addButton]
        guard let anchor = stops.firstIndex(where: { $0 === view }) else { return }
        SettingsDetail.moveFocus(stops: stops, from: anchor, delta: delta) { $0 }
    }
}

/// One Tools row: a float's icon, title, an id · command subtitle, and its shortcut keycap. The whole
/// row is one focus stop — Return / click opens the edit form (where delete lives), Up/Down move rows,
/// Left exits to nav, Esc closes. Mirrors `KeybindRow`.
final class ToolFloatRow: NSView {
    let float: ToolFloat
    var onActivate: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onExitToNav: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let keycap: KeycapView
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
        let controls = NSStackView(views: [iconView, labels, spacer, keycap])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        iconView.contentTintColor = Theme.current.chrome.ink(alpha: 0.75)
        titleLabel.textColor = Theme.current.chrome.foreground.nsColor
        subtitleLabel.textColor = Theme.current.chrome.ink(alpha: 0.5)
        keycap.reapplyTheme()
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
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .left: onExitToNav?()
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
