import AppKit

/// One left-nav entry in the Settings card: a selectable, keyboard-focusable label. Focus reads
/// as an accent background fill — the same highlight the command palette and repo picker rows use
/// (`PaletteOverlay.selectionBackground`), not a border — over a subtler selected-section fill.
/// Keyboard follows the shared 2D model (Up/Down move, Right/Tab enter the detail pane; Esc closes
/// the card, owned by the card root — see `ModalEscape`).
final class SettingsNavRow: NSView {
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    /// Shift-Tab retreats a row like Up, but wraps at the first row (Up clamps) — so the nav's
    /// Shift-Tab is a loop, matching the detail pane's wrapping Tab loop instead of dead-ending.
    var onBacktab: (() -> Void)?
    var onEnterDetail: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let onActivate: () -> Void
    private var isSelected = false
    private var isFocusedStop = false

    init(title: String, onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        label.stringValue = title
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.current.chrome.foreground.nsColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        refreshFill()
    }

    /// Re-apply the live chrome colors after a config change — no relaunch. `refreshFill()`
    /// already reads `Theme.current` fresh, but doesn't touch `label` (set once in init).
    func reapplyTheme() {
        label.textColor = Theme.current.chrome.foreground.nsColor
        refreshFill()
    }

    private func refreshFill() {
        if isFocusedStop {
            // Share the palette/repo-picker row highlight so every focus background matches.
            layer?.backgroundColor = PaletteOverlay.selectionBackground.cgColor
        } else if isSelected {
            layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.06).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocusedStop = true; refreshFill(); return true }
    override func resignFirstResponder() -> Bool { isFocusedStop = false; refreshFill(); return true }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onActivate() }

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .up: onArrowUp?()  // clamps at the first row
        case .tab(shift: true): onBacktab?()  // Shift-Tab retreats a row and wraps at the first
        case .down: onArrowDown?()
        case .right, .tab(shift: false): onEnterDetail?()  // Right or Tab enters the detail pane
        default: super.keyDown(with: event)
        }
    }
}
