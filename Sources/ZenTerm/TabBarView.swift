import AppKit
import TabKit

struct TabBarItem {
    let id: TabID
    let index: Int      // 1-based number shown before the title
    let title: String
    let isActive: Bool
}

/// The bottom-left numbered tab bar. Stateless beyond its last rendered snapshot;
/// selection/close/new all flow out through callbacks. Clicking a tab selects it;
/// middle-clicking a tab closes it; the trailing "+" makes a new tab.
final class TabBarView: NSView {
    private let onSelect: (TabID) -> Void
    private let onClose: (TabID) -> Void
    private let onNewTab: () -> Void

    static let height: CGFloat = 28

    private static let iris = NSColor(srgbRed: 0xc4 / 255.0, green: 0xa7 / 255.0, blue: 0xe7 / 255.0, alpha: 1)
    private static let activeInk = NSColor(white: 0.92, alpha: 1)
    private static let idleInk = NSColor(white: 0.92, alpha: 0.5)
    private static let numberInk = NSColor(white: 0.92, alpha: 0.35)

    private let stack = NSStackView()

    init(onSelect: @escaping (TabID) -> Void,
         onClose: @escaping (TabID) -> Void,
         onNewTab: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onClose = onClose
        self.onNewTab = onNewTab
        super.init(frame: .zero)
        wantsLayer = true
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(_ items: [TabBarItem]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            stack.addArrangedSubview(TabButton(item: item,
                                               onSelect: onSelect,
                                               onClose: onClose))
        }
        let plus = NSButton(title: "+", target: self, action: #selector(newTabTapped))
        plus.isBordered = false
        plus.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        plus.contentTintColor = Self.idleInk
        stack.addArrangedSubview(plus)
    }

    @objc private func newTabTapped() { onNewTab() }

    /// One tab entry: `N title` with an iris underline when active.
    private final class TabButton: NSView {
        private let id: TabID
        private let onSelect: (TabID) -> Void
        private let onClose: (TabID) -> Void
        private let underline = NSView()

        init(item: TabBarItem, onSelect: @escaping (TabID) -> Void, onClose: @escaping (TabID) -> Void) {
            self.id = item.id
            self.onSelect = onSelect
            self.onClose = onClose
            super.init(frame: .zero)
            wantsLayer = true

            let label = NSTextField(labelWithAttributedString: Self.attributed(item))
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)

            underline.wantsLayer = true
            underline.layer?.backgroundColor = TabBarView.iris.cgColor
            underline.isHidden = !item.isActive
            underline.translatesAutoresizingMaskIntoConstraints = false
            addSubview(underline)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
                label.topAnchor.constraint(equalTo: topAnchor),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
                underline.leadingAnchor.constraint(equalTo: leadingAnchor),
                underline.trailingAnchor.constraint(equalTo: trailingAnchor),
                underline.bottomAnchor.constraint(equalTo: bottomAnchor),
                underline.heightAnchor.constraint(equalToConstant: 2),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        private static func attributed(_ item: TabBarItem) -> NSAttributedString {
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            let ink = item.isActive ? TabBarView.activeInk : TabBarView.idleInk
            let s = NSMutableAttributedString(
                string: "\(item.index) ",
                attributes: [.font: font, .foregroundColor: TabBarView.numberInk])
            s.append(NSAttributedString(
                string: item.title,
                attributes: [.font: font, .foregroundColor: ink,
                             .kern: 0.5]))
            return s
        }

        override func mouseDown(with event: NSEvent) { onSelect(id) }
        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 { onClose(id) }   // middle-click closes
        }
    }
}
