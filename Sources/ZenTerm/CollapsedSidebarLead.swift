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
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        func run(_ text: String, _ ink: ChromeTheme.InkLevel) -> NSAttributedString {
            NSAttributedString(
                string: text,
                attributes: [
                    .font: TabBarView.chipFont, .kern: TabBarView.titleKern, .foregroundColor: chrome.ink(ink),
                    .paragraphStyle: paragraph,
                ])
        }
        let label = NSMutableAttributedString(attributedString: run(name, .muted))
        if let worktree {
            label.append(run(" / ", .faint))
            label.append(run(worktree, .subtle))
        }
        nameLabel.attributedStringValue = Self.fitted(label)
    }

    // Cut by count: AppKit's tail truncation stops short of the width and widens the divider's gap.
    private static let maxCharacters: Int = {
        let cell = NSAttributedString(
            string: "0", attributes: [.font: TabBarView.chipFont, .kern: TabBarView.titleKern]
        ).size().width
        return Int(TabBarView.maxChipWidth / cell)
    }()

    private static func fitted(_ label: NSAttributedString) -> NSAttributedString {
        let text = label.string
        guard text.count > maxCharacters else { return label }
        let kept = NSRange(text.startIndex..<text.index(text.startIndex, offsetBy: maxCharacters - 1), in: text)
        let fitted = NSMutableAttributedString(attributedString: label.attributedSubstring(from: kept))
        fitted.append(
            NSAttributedString(string: "…", attributes: label.attributes(at: kept.length - 1, effectiveRange: nil)))
        return fitted
    }

    func reapplyTheme() {
        setWorkspaceName(workspaceName, worktree: worktreeName)
        divider.layer?.backgroundColor = Theme.current.chrome.fill(alpha: ChromeTheme.border).cgColor
    }

    var workspaceNameForTesting: String { nameLabel.stringValue }
    var workspaceNameLabelForTesting: NSView { nameLabel }
}
