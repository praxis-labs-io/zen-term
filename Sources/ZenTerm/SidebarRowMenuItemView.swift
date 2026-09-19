import AppKit

final class SidebarRowMenuItemView: NSView {
    let title: String
    private let label: NSTextField
    private let shortcut: NSTextField
    private let onChoose: () -> Void
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    private static let inset: CGFloat = 9
    private static let gap: CGFloat = 12

    init(_ item: SidebarRowMenu.Item, onChoose: @escaping () -> Void) {
        title = item.title
        label = NSTextField(labelWithString: item.title)
        shortcut = NSTextField(labelWithString: CommandCatalog.spec(for: item.action).shortcut ?? "")
        self.onChoose = onChoose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcut.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        shortcut.setContentHuggingPriority(.required, for: .horizontal)
        for field in [label, shortcut] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -Self.gap),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var shortcutForTesting: String { shortcut.stringValue }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        label.textColor = chrome.foreground.nsColor
        shortcut.textColor = chrome.ink(.muted)
        layer?.backgroundColor = isHovered ? chrome.selectionFill.cgColor : NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        reapplyTheme()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        reapplyTheme()
    }

    override func mouseDown(with event: NSEvent) { onChoose() }

    override func accessibilityPerformPress() -> Bool {
        onChoose()
        return true
    }
}
