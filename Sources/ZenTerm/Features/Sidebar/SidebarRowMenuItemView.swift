import AppKit

final class SidebarRowMenuItemView: ControlView, ThemeReapplying {
    let title: String
    private let label: NSTextField
    private let keycap: KeycapView?
    private let onChoose: () -> Void

    private static let inset: CGFloat = ChromeMetrics.Spacing.controlInset
    private static let gap: CGFloat = ChromeMetrics.Spacing.s12

    init(_ item: SidebarRowMenu.Item, onChoose: @escaping () -> Void) {
        title = item.title
        label = NSTextField(labelWithString: item.title)
        let shortcut = item.action.map { CommandCatalog.spec(for: $0).shortcut } ?? ""
        keycap = shortcut.isEmpty ? nil : KeycapView(shortcut: shortcut)
        self.onChoose = onChoose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ChromeMetrics.Radius.control
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
        label.font = ChromeType.font(.body)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if let keycap {
            addSubview(keycap)
            NSLayoutConstraint.activate([
                label.trailingAnchor.constraint(lessThanOrEqualTo: keycap.leadingAnchor, constant: -Self.gap),
                keycap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
                keycap.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        } else {
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.inset).isActive = true
        }
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var shortcutForTesting: String { keycap?.shortcut ?? "" }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        label.textColor = chrome.ink(.normal)
        easeFill(isHovered ? chrome.fill(.hover) : .clear)
    }

    override func hoverDidChange() { reapplyTheme() }

    override func mouseDown(with event: NSEvent) { onChoose() }

    override func accessibilityPerformPress() -> Bool {
        onChoose()
        return true
    }
}
