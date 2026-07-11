import AppKit

/// Shared scaffolding for the Settings card's scrolling detail sections — the flipped-document
/// scroll wrapper and the Reset-all success flash — so each section doesn't re-hand-roll them.
enum SettingsDetail {
    /// Wrap a section's rows stack in the standard detail scroll: a flipped document (top-down
    /// coords, so it opens at the top), a slim auto-hiding overlay scroller, and the shared content
    /// insets (18 top/bottom, 20 leading/trailing). The rows stack becomes the document's content.
    static func scroll(for rowsStack: NSStackView) -> NSScrollView {
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = SlimScroller()
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rowsStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 18),
            rowsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            rowsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
            rowsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -18),
        ])
        return scroll
    }
}

/// The "Defaults restored." line tucked under a section's Reset-all button: a muted-accent label
/// that flashes on reset and auto-hides after a couple seconds. Shared by the Settings sections.
final class ResetFlashLabel: NSTextField {
    private var hideTimer: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 11, weight: .medium)
        textColor = Theme.current.chrome.accent.nsColor
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Show the message, then fade it after a beat. Re-flashing restarts the timer.
    func flash(_ text: String) {
        stringValue = text
        isHidden = false
        let hide = DispatchWorkItem { [weak self] in self?.isHidden = true }
        hideTimer?.cancel()
        hideTimer = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: hide)
    }
}
