import AppKit

enum SettingsDetail {
    static func scroll(for rowsStack: NSStackView) -> NSScrollView {
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)

        let scroll = FadingScrollView()
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

    static func groupCaption(_ title: String) -> NSTextField {
        let caption = NSTextField(labelWithString: title.uppercased())
        caption.font = .systemFont(ofSize: 10, weight: .semibold)
        caption.textColor = Theme.current.chrome.ink(.muted)
        return caption
    }

    static func reorderHint() -> NSTextField {
        let hint = NSTextField(labelWithString: "⌥↑ ⌥↓ to reorder")
        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = Theme.current.chrome.ink(.faint)
        hint.setContentHuggingPriority(.required, for: .horizontal)
        return hint
    }

    static func headerRow(caption: NSTextField, hint: NSTextField?) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [caption, spacer] + (hint.map { [$0] } ?? []))
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    static func moveFocus(
        stops: [NSView], from anchor: Int?, delta: Int, wrap: Bool = false,
        scrollTarget: (NSView) -> NSView
    ) {
        guard let next = KeyboardFocus.step(from: anchor, delta: delta, count: stops.count, wrap: wrap)
        else { return }
        let target = stops[next]
        target.window?.makeFirstResponder(target)
        let travel: KeyboardFocus.Travel =
            switch anchor {
            case .some(let from) where next < from: .up
            case .some: .down
            case nil: .unknown
            }
        KeyboardFocus.reveal(scrollTarget(target), among: stops, travelling: travel)
    }

    static func trailingRow(_ view: NSView) -> NSStackView {
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer, view])
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }
}

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

    func flash(_ text: String) {
        stringValue = text
        isHidden = false
        let hide = DispatchWorkItem { [weak self] in self?.isHidden = true }
        hideTimer?.cancel()
        hideTimer = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: hide)
    }

    func reapplyTheme() {
        textColor = Theme.current.chrome.accent.nsColor
    }
}
