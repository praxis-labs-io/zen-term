import AppKit

/// A small themed button on a confirm toast. Borderless + layer-drawn so it
/// matches the card chrome; carries its `ToastAction.run` and — for primary /
/// cancel — the Return / Esc key equivalents that answer the confirm.
final class ToastButton: NSButton {
    private let run: () -> Void

    // Rosé Pine Moon: love (destructive), gold (primary), muted subtle (cancel).
    private static let love = NSColor(srgbRed: 0xeb / 255, green: 0x6f / 255, blue: 0x92 / 255, alpha: 1)
    private static let gold = NSColor(srgbRed: 0xf6 / 255, green: 0xc1 / 255, blue: 0x77 / 255, alpha: 1)
    private static let subtle = NSColor(srgbRed: 0x90 / 255, green: 0x8c / 255, blue: 0xaa / 255, alpha: 1)
    private static let base = NSColor(srgbRed: 0x19 / 255, green: 0x17 / 255, blue: 0x24 / 255, alpha: 1)

    init(_ action: ToastAction) {
        self.run = action.run
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        wantsLayer = true
        bezelStyle = .rounded
        layer?.cornerRadius = 7
        setButtonType(.momentaryChange)
        target = self
        self.action = #selector(fire)

        let (fill, border, text): (NSColor?, NSColor, NSColor)
        switch action.kind {
        case .destructive: (fill, border, text) = (Self.love, .clear, .white)
        case .primary: (fill, border, text) = (Self.gold, .clear, Self.base)
        case .cancel: (fill, border, text) = (nil, FloatShadow.edge, Self.subtle)
        }
        layer?.backgroundColor = (fill ?? .clear).cgColor
        layer?.borderWidth = fill == nil ? 1 : 0
        layer?.borderColor = border.cgColor
        attributedTitle = NSAttributedString(
            string: action.title,
            attributes: [
                .foregroundColor: text,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            ])

        switch action.kind {
        case .destructive, .primary: keyEquivalent = "\r"  // Return answers
        case .cancel: keyEquivalent = "\u{1b}"  // Esc cancels
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { run() }
}
