import AppKit

/// A small, flat button on a confirm toast: a muted `cancel`, or a subtle-filled
/// `destructive` whose destructive-tinted text carries the tone. Carries its
/// `ToastAction.run`, and —
/// unless `keyEquivalents` is off (a non-modal toast that must not hijack Return / Esc
/// window-wide) — the Return / Esc keys.
final class ToastButton: NSButton {
    private let run: () -> Void
    private let restBg: NSColor
    private let hoverBg: NSColor
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false { didSet { updateBackground() } }

    private static let subtle = NSColor(white: 1, alpha: 0.07)
    private static let subtleHover = NSColor(white: 1, alpha: 0.12)

    init(_ action: ToastAction, keyEquivalents: Bool = true) {
        self.run = action.run
        let text: NSColor
        switch action.kind {
        case .cancel:
            (restBg, hoverBg, text) = (.clear, Self.subtle, Theme.current.chrome.muted.nsColor)
        case .destructive:
            (restBg, hoverBg, text) = (Self.subtle, Self.subtleHover, Theme.current.chrome.destructive.nsColor)
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

        if keyEquivalents {
            switch action.kind {
            case .destructive: keyEquivalent = "\r"  // Return answers
            case .cancel: keyEquivalent = "\u{1b}"  // Esc cancels
            }
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
