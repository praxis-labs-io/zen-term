import AppKit

/// One left-nav entry in the Settings card: a selectable, keyboard-focusable label. Selected
/// reads as a muted accent fill; focus is the shared 2D model (Up/Down move, Right/Tab enter
/// the detail pane, Esc closes).
final class SettingsNavRow: NSView {
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onEnterDetail: (() -> Void)?
    var onEsc: (() -> Void)?

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
            layer?.backgroundColor = Theme.current.chrome.accent.nsColor.withAlphaComponent(0.18).cgColor
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
        switch event.keyCode {
        case 126: onArrowUp?()  // Up
        case 125: onArrowDown?()  // Down
        case 124, 48: onEnterDetail?()  // Right, Tab
        case 53: onEsc?()  // Esc
        default: super.keyDown(with: event)
        }
    }
}
