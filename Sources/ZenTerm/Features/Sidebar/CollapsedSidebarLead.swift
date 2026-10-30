import AppKit

// Leads the tab bar with the active workspace's name while the sidebar is collapsed.
final class CollapsedSidebarLead: NSView, ThemeReapplying {
    static let tabGap: CGFloat = ChromeMetrics.Spacing.s4

    private let nameLabel = NSTextField(labelWithString: "")
    private var workspaceName = ""
    private var worktreeName: String?
    private let content = NSStackView()

    init(leadingInset: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true

        nameLabel.font = TabChip.chipFont
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: TabChip.maxChipWidth).isActive = true
        content.orientation = .horizontal
        content.alignment = .centerY
        setLeadingInset(leadingInset)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(nameLabel)
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

    func setLeadingInset(_ inset: CGFloat) {
        content.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: 0)
    }

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
                    .font: TabChip.chipFont, .kern: TabChip.titleKern, .foregroundColor: chrome.ink(ink),
                    .paragraphStyle: paragraph,
                ])
        }
        let label = NSMutableAttributedString(attributedString: run(name, .muted))
        if let worktree {
            label.append(run(" / ", .faint))
            label.append(run(worktree, .subtle))
        }
        let shown = NSMutableAttributedString(attributedString: Self.fitted(label))
        shown.append(run(":", worktree == nil ? .muted : .subtle))
        nameLabel.attributedStringValue = shown
    }

    // Cut by count, one short for the colon: AppKit's tail truncation stops short of the width and widens the gap.
    private static let maxCharacters: Int = {
        let cell = NSAttributedString(
            string: "0", attributes: [.font: TabChip.chipFont, .kern: TabChip.titleKern]
        ).size().width
        return Int(TabChip.maxChipWidth / cell) - 1
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
    }

    var workspaceNameForTesting: String { nameLabel.stringValue }
    var workspaceNameLabelForTesting: NSView { nameLabel }
}
