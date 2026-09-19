import AppKit

// Leads the tab bar with the active workspace's name while the sidebar is collapsed.
final class CollapsedSidebarLead: NSView {
    static let dividerGap: CGFloat = 12

    private let nameLabel = NSTextField(labelWithString: "")
    private var workspaceName = ""
    private var worktreeName: String?
    private let divider = ToggleDock.divider()
    private let content = NSStackView()

    init(leadingInset: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true

        nameLabel.font = TabBarView.chipFont
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: TabBarView.maxChipWidth).isActive = true
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Self.dividerGap
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

    func setWorkspaceName(_ name: String, worktree: String? = nil) {
        workspaceName = name
        worktreeName = worktree
        let chrome = Theme.current.chrome
        func run(_ text: String, _ ink: ChromeTheme.InkLevel) -> NSAttributedString {
            NSAttributedString(
                string: text,
                attributes: [
                    .font: TabBarView.chipFont, .kern: TabBarView.titleKern, .foregroundColor: chrome.ink(ink),
                ])
        }
        let label = NSMutableAttributedString(attributedString: run(name, .muted))
        if let worktree {
            label.append(run(" / ", .faint))
            label.append(run(worktree, .subtle))
        }
        nameLabel.attributedStringValue = label
    }

    func reapplyTheme() {
        setWorkspaceName(workspaceName, worktree: worktreeName)
        divider.layer?.backgroundColor = Theme.current.chrome.fill(alpha: ChromeTheme.border).cgColor
    }

    var workspaceNameForTesting: String { nameLabel.stringValue }
    var workspaceNameLabelForTesting: NSView { nameLabel }
}
