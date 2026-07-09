import AppKit

/// A small, flat button on a confirm toast: muted `cancel`, or a subtle-filled `primary` /
/// `destructive` whose text carries the tone (the toast's `accent` for primary, love for
/// destructive). Carries its `ToastAction.run` and the Return / Esc key equivalents.
final class ToastButton: NSButton {
    private let run: () -> Void
    private let restBg: NSColor
    private let hoverBg: NSColor
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false { didSet { updateBackground() } }

    private static let love = NSColor(srgbRed: 0xeb / 255, green: 0x6f / 255, blue: 0x92 / 255, alpha: 1)
    private static let muted = NSColor(srgbRed: 0x90 / 255, green: 0x8c / 255, blue: 0xaa / 255, alpha: 1)
    private static let subtle = NSColor(white: 1, alpha: 0.07)
    private static let subtleHover = NSColor(white: 1, alpha: 0.12)

    init(_ action: ToastAction, accent: NSColor) {
        self.run = action.run
        let text: NSColor
        switch action.kind {
        case .cancel:
            (restBg, hoverBg, text) = (.clear, Self.subtle, Self.muted)
        case .primary:
            (restBg, hoverBg, text) = (Self.subtle, Self.subtleHover, accent)
        case .destructive:
            (restBg, hoverBg, text) = (Self.subtle, Self.subtleHover, Self.love)
        }

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        setButtonType(.momentaryChange)
        target = self
        self.action = #selector(fire)
        attributedTitle = NSAttributedString(
            string: action.title,
            attributes: [
                .foregroundColor: text,
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            ])

        switch action.kind {
        case .destructive, .primary: keyEquivalent = "\r"  // Return answers
        case .cancel: keyEquivalent = "\u{1b}"  // Esc cancels
        }

        updateBackground()
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func updateBackground() {
        layer?.backgroundColor = (isHovered ? hoverBg : restBg).cgColor
    }

    @objc private func fire() { run() }
}
