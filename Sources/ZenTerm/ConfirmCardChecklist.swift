import AppKit
import TerminalKit

final class ConfirmCardChecklist: NSView, ThemeReapplying {
    enum Mark: Equatable {
        case lost
        case warning
        case info
        case kept

        var symbol: String {
            switch self {
            case .lost: return "xmark"
            case .warning: return "exclamationmark.triangle"
            case .info: return "info.circle"
            case .kept: return "checkmark"
            }
        }

        var role: KeyPath<ChromeTheme, TerminalColor> {
            switch self {
            case .lost: return \.destructive
            case .warning: return \.warning
            case .info: return \.info
            case .kept: return \.positive
            }
        }
    }

    struct Item: Equatable {
        let mark: Mark
        let text: [ConfirmCardList.Run]
        let rows: [ConfirmCardList.Row]
    }

    static let textFont = NSFont.systemFont(ofSize: 12)
    static let iconSize = NSSize(width: 14, height: 15)
    static let listIndent: CGFloat = 22

    private let itemViews: [ItemView]

    init(items: [Item]) {
        itemViews = items.map(ItemView.init)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: itemViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for view in itemViews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reapplyTheme() {
        itemViews.forEach { $0.reapplyTheme() }
    }

    private final class ItemView: NSView {
        private let item: Item
        private let icon = NSImageView()
        private let label = NSTextField(wrappingLabelWithString: "")
        private let list: ConfirmCardList?

        init(_ item: Item) {
            self.item = item
            list = item.rows.isEmpty ? nil : ConfirmCardList(rows: item.rows)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            icon.image = NSImage(systemSymbolName: item.mark.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            icon.imageScaling = .scaleProportionallyDown
            for view in [icon, label] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            label.isSelectable = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor),
                icon.topAnchor.constraint(equalTo: topAnchor),
                icon.widthAnchor.constraint(equalToConstant: ConfirmCardChecklist.iconSize.width),
                icon.heightAnchor.constraint(equalToConstant: ConfirmCardChecklist.iconSize.height),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
                label.topAnchor.constraint(equalTo: topAnchor),
            ])
            guard let list else {
                label.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
                return
            }
            addSubview(list)
            NSLayoutConstraint.activate([
                list.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
                list.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ConfirmCardChecklist.listIndent),
                list.trailingAnchor.constraint(equalTo: trailingAnchor),
                list.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func reapplyTheme() {
            let chrome = Theme.current.chrome
            icon.contentTintColor = chrome[keyPath: item.mark.role].nsColor
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            label.attributedStringValue = item.text.reduce(into: NSMutableAttributedString()) { out, run in
                out.append(
                    NSAttributedString(
                        string: run.text,
                        attributes: [
                            .font: ConfirmCardChecklist.textFont, .paragraphStyle: paragraph,
                            .foregroundColor: ConfirmCardList.color(run.tone, chrome),
                        ]))
            }
            list?.reapplyTheme()
        }
    }
}
