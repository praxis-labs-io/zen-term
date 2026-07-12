import AppKit

/// One left-nav entry in the Settings card: a selectable, keyboard-focusable label. Selected
/// reads as a subtle fill; focus adds an accent ring — the same focus outline `AppButton`,
/// `Dropdown`, and the segments use — so a focused selected row shows both. Keyboard follows the
/// shared 2D model (Up/Down move, Right/Tab enter the detail pane, Esc closes).
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
        restyle()
    }

    /// Re-apply the live chrome colors after a config change — no relaunch. `restyle()` already
    /// reads `Theme.current` fresh, but doesn't touch `label` (set once in init).
    func reapplyTheme() {
        label.textColor = Theme.current.chrome.foreground.nsColor
        restyle()
    }

    private func restyle() {
        let chrome = Theme.current.chrome
        // Selection is a subtle fill; focus is an accent ring layered on top — so the fill and the
        // ring are independent and a focused selected row shows both.
        layer?.backgroundColor = (isSelected ? chrome.ink(alpha: 0.06) : .clear).cgColor
        layer?.borderWidth = isFocusedStop ? 1.5 : 0
        layer?.borderColor = isFocusedStop ? chrome.accent.nsColor.cgColor : nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocusedStop = true; restyle(); return true }
    override func resignFirstResponder() -> Bool { isFocusedStop = false; restyle(); return true }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onActivate() }

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .up: onArrowUp?()
        case .down: onArrowDown?()
        case .right, .tab: onEnterDetail?()  // Right or Tab enters the detail pane
        case .escape: onEsc?()
        default: super.keyDown(with: event)
        }
    }
}
