import AppKit
import TabKit

struct TabBarItem {
    let id: TabID
    let index: Int  // 1-based number shown before the title
    let title: String
    let isActive: Bool
}

/// The bottom-left numbered tab bar. Stateless beyond its last rendered snapshot;
/// selection/close/new all flow out through callbacks. Clicking a tab selects it;
/// middle-clicking a tab closes it; the trailing "+" chip makes a new tab. The
/// active tab is marked with an iris underline; the rounded box is a hover-only
/// affordance shared by tabs and the "+".
final class TabBarView: NSView {
    private let onSelect: (TabID) -> Void
    private let onClose: (TabID) -> Void
    private let onNewTab: () -> Void

    static let height: CGFloat = 30

    fileprivate static let iris = NSColor(srgbRed: 0xc4 / 255.0, green: 0xa7 / 255.0, blue: 0xe7 / 255.0, alpha: 1)
    fileprivate static let activeInk = NSColor(white: 0.95, alpha: 1)
    fileprivate static let idleInk = NSColor(white: 0.92, alpha: 0.55)
    fileprivate static let numberInk = NSColor(white: 0.92, alpha: 0.35)

    private let stack = NSStackView()

    init(
        onSelect: @escaping (TabID) -> Void,
        onClose: @escaping (TabID) -> Void,
        onNewTab: @escaping () -> Void
    ) {
        self.onSelect = onSelect
        self.onClose = onClose
        self.onNewTab = onNewTab
        super.init(frame: .zero)
        wantsLayer = true
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Nudge up by half the pane canvas's 12pt bottom gutter so the chips read as
        // centered in the whole band between the terminal content and the window edge,
        // not just within this bar's own height. (This view's superview is flipped, so
        // a negative centerY constant moves the stack visually up.)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(_ items: [TabBarItem]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            let id = item.id
            let chip = Chip(
                attributed: Self.tabLabel(item), isActive: item.isActive, showsUnderline: true,
                onClick: { [weak self] in self?.onSelect(id) },
                onMiddleClick: { [weak self] in self?.onClose(id) })
            stack.addArrangedSubview(chip)
        }
        let plus = IconButton(
            symbol: "plus", size: NSSize(width: 22, height: 22),
            pointSize: 11, accessibilityLabel: "New tab",
            onClick: { [weak self] in self?.onNewTab() })
        stack.addArrangedSubview(plus)
    }

    private static func tabLabel(_ item: TabBarItem) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let ink = item.isActive ? activeInk : idleInk
        let s = NSMutableAttributedString(
            string: "\(item.index) ",
            attributes: [.font: font, .foregroundColor: numberInk])
        s.append(
            NSAttributedString(
                string: item.title,
                attributes: [.font: font, .foregroundColor: ink, .kern: 0.4]))
        return s
    }

    /// A rounded box holding a centered label. The box background appears on hover
    /// only; an active tab is marked by an iris underline instead. Used for both tabs
    /// and the "+" affordance so they share hover feel and stay vertically aligned.
    private final class Chip: NSView {
        private let onClick: () -> Void
        private let onMiddleClick: (() -> Void)?
        private var isHovered = false
        private let underline = NSView()

        init(
            attributed: NSAttributedString, isActive: Bool, showsUnderline: Bool,
            onClick: @escaping () -> Void, onMiddleClick: (() -> Void)?
        ) {
            self.onClick = onClick
            self.onMiddleClick = onMiddleClick
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 6

            let label = NSTextField(labelWithAttributedString: attributed)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)

            underline.wantsLayer = true
            underline.layer?.backgroundColor = TabBarView.iris.cgColor
            underline.isHidden = !(isActive && showsUnderline)
            underline.translatesAutoresizingMaskIntoConstraints = false
            addSubview(underline)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                heightAnchor.constraint(equalToConstant: 22),
                underline.leadingAnchor.constraint(equalTo: label.leadingAnchor),
                underline.trailingAnchor.constraint(equalTo: label.trailingAnchor),
                underline.bottomAnchor.constraint(equalTo: bottomAnchor),
                underline.heightAnchor.constraint(equalToConstant: 2),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                    owner: self))
        }

        override func mouseEntered(with event: NSEvent) { isHovered = true; updateBackground() }
        override func mouseExited(with event: NSEvent) { isHovered = false; updateBackground() }
        override func mouseDown(with event: NSEvent) { onClick() }
        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 { onMiddleClick?() }  // middle-click closes
        }

        private func updateBackground() {
            layer?.backgroundColor = (isHovered ? NSColor(white: 1, alpha: 0.08) : .clear).cgColor
        }
    }
}
