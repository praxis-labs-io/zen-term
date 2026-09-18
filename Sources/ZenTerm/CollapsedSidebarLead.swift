import AppKit

/// Leads the tab bar while the sidebar is collapsed with the active workspace's name, clear of the sidebar toggle.
final class CollapsedSidebarLead: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let divider = ToggleDock.divider()
    private let content = NSStackView()

    init(leadingInset: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true

        nameLabel.font = TabBarView.chipFont
        nameLabel.lineBreakMode = .byTruncatingTail
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 0, left: leadingInset, bottom: 0, right: 0)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(nameLabel)
        content.addArrangedSubview(divider)
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
        setWorkspaceName(nameLabel.stringValue)
        divider.layer?.backgroundColor = Theme.current.chrome.fill(alpha: ChromeTheme.border).cgColor
    }

    var workspaceNameForTesting: String { nameLabel.stringValue }
}
