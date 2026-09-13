import AppKit
import TerminalKit

final class ConfirmCardList: NSView, ThemeReapplying {
    enum Tone: Equatable {
        case ink(ChromeTheme.InkLevel)
        case role(KeyPath<ChromeTheme, TerminalColor>)
    }

    struct Run: Equatable {
        let text: String
        let tone: Tone
    }

    enum Row: Equatable {
        case entry(path: [Run], status: [[Run]])
        case note(String)
    }

    static let rowHeight: CGFloat = 20
    static let pathFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let noteFont = NSFont.systemFont(ofSize: 12)

    private let rowViews: [RowView]

    init(rows: [Row]) {
        rowViews = rows.map(RowView.init)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        let stack = NSStackView(views: rowViews)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        for row in rowViews {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        }
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        layer?.borderColor = Theme.current.chrome.fill(alpha: ChromeTheme.border).cgColor
        rowViews.forEach { $0.reapplyTheme() }
    }

    private final class RowView: NSView {
        private let row: Row
        private let leading = NSTextField(labelWithString: "")
        private let trailing = NSTextField(labelWithString: "")

        init(_ row: Row) {
            self.row = row
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            for label in [leading, trailing] {
                label.translatesAutoresizingMaskIntoConstraints = false
                label.maximumNumberOfLines = 1
                addSubview(label)
            }
            leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            leading.setContentHuggingPriority(.defaultLow, for: .horizontal)
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                leading.centerYAnchor.constraint(equalTo: centerYAnchor),
                trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
                trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 8),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func reapplyTheme() {
            let chrome = Theme.current.chrome
            switch row {
            case .entry(let path, let status):
                leading.attributedStringValue = Self.text(
                    path, font: ConfirmCardList.pathFont, truncation: .byTruncatingMiddle, chrome: chrome)
                let groups = status.map {
                    Self.text($0, font: StatusTokens.font, truncation: .byClipping, chrome: chrome)
                }
                trailing.attributedStringValue = StatusTokens.joined(groups)
            case .note(let text):
                leading.attributedStringValue = Self.text(
                    [Run(text: text, tone: .ink(.muted))], font: ConfirmCardList.noteFont,
                    truncation: .byTruncatingTail, chrome: chrome)
                trailing.attributedStringValue = NSAttributedString()
            }
        }

        private static func paragraph(_ truncation: NSLineBreakMode) -> NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = truncation
            return paragraph
        }

        private static func text(
            _ runs: [Run], font: NSFont, truncation: NSLineBreakMode, chrome: ChromeTheme
        ) -> NSAttributedString {
            let paragraph = paragraph(truncation)
            let out = NSMutableAttributedString()
            for run in runs {
                out.append(
                    NSAttributedString(
                        string: run.text,
                        attributes: [
                            .font: font, .paragraphStyle: paragraph, .foregroundColor: color(run.tone, chrome),
                        ]))
            }
            return out
        }

        private static func color(_ tone: Tone, _ chrome: ChromeTheme) -> NSColor {
            switch tone {
            case .ink(let level): return chrome.ink(level)
            case .role(let role): return chrome[keyPath: role].nsColor
            }
        }
    }
}
