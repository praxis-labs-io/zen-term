import AppKit

/// Leads the tab bar while the sidebar is collapsed: its toggle, then the active workspace's name.
final class CollapsedSidebarLead: NSView {
    private static let inset: CGFloat = 8
    private static let buttonSize = NSSize(width: 22, height: 22)
    private static let iconPointSize: CGFloat = 11

    private let toggleButton: IconButton
    private let nameLabel = NSTextField(labelWithString: "")
    private let divider = ToggleDock.divider()
    private let content = NSStackView()

    init(onToggle: @escaping () -> Void) {
        toggleButton = IconButton(
            symbol: "sidebar.left", size: Self.buttonSize, pointSize: Self.iconPointSize,
            accessibilityLabel: "Toggle sidebar", shortcut: { CommandCatalog.spec(for: .toggleSidebar).shortcut },
            onClick: onToggle)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true

        nameLabel.font = TabBarView.chipFont
        nameLabel.lineBreakMode = .byTruncatingTail
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 4
        content.edgeInsets = NSEdgeInsets(top: 0, left: Self.inset, bottom: 0, right: 0)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(toggleButton)
        content.addArrangedSubview(nameLabel)
        content.addArrangedSubview(divider)
        content.setCustomSpacing(6, after: toggleButton)
        content.setCustomSpacing(8, after: nameLabel)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var contentWidth: CGFloat { content.fittingSize.width }

    func setWorkspaceName(_ name: String) {
        nameLabel.attributedStringValue = NSAttributedString(
            string: name,
            attributes: [
                .font: TabBarView.chipFont, .kern: TabBarView.titleKern,
                .foregroundColor: Theme.current.chrome.ink(.muted),
            ])
    }

    func reapplyTheme() {
        toggleButton.reapplyTheme()
        setWorkspaceName(nameLabel.stringValue)
        divider.layer?.backgroundColor = Theme.current.chrome.fill(alpha: ChromeTheme.border).cgColor
    }

    var toggleButtonForTesting: IconButton { toggleButton }
    var workspaceNameForTesting: String { nameLabel.stringValue }
}
