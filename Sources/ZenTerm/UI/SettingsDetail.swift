import AppKit

enum SettingsDetail {
    // A list's rows reach this far past the content edge, so their fill bleeds into the gutter while their text aligns.
    static let listOutset = ChromeMetrics.Spacing.controlInset

    static func pinToListContent(_ view: NSView, in stack: NSStackView) {
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(listOutset + listOutset)).isActive = true
    }

    static func scroll(for rowsStack: NSStackView, outset: CGFloat = 0) -> NSScrollView {
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)

        let scroll = FadingScrollView(document: doc)

        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rowsStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: ChromeMetrics.Spacing.modalInsets.top),
            rowsStack.leadingAnchor.constraint(
                equalTo: doc.leadingAnchor, constant: ChromeMetrics.Spacing.modalInsets.left - outset),
            rowsStack.trailingAnchor.constraint(
                equalTo: doc.trailingAnchor, constant: -ChromeMetrics.Spacing.modalInsets.right + outset),
            rowsStack.bottomAnchor.constraint(
                equalTo: doc.bottomAnchor, constant: -ChromeMetrics.Spacing.modalInsets.bottom),
        ])
        return scroll
    }

    static let captionGap = ChromeMetrics.Spacing.s10
    static let rowGap = ChromeMetrics.Spacing.s4
    static let groupGap = ChromeMetrics.Spacing.s20

    // A one-line row centers its label in `Height.lg`, so the caption gap above it gives back that inset.
    static func gap(belowCaptionAbove label: NSTextField) -> CGFloat {
        captionGap - max(0, (ChromeMetrics.Height.lg - label.intrinsicContentSize.height) / 2)
    }

    static func reorderHint() -> NSTextField {
        let hint = NSTextField(labelWithString: "⌥↑ ⌥↓ to reorder")
        hint.font = ChromeType.font(.caption, weight: .medium)
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
        row.spacing = ChromeMetrics.Spacing.s8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    static func moveFocus(
        stops: [NSView], from anchor: Int?, delta: Int, wrap: Bool = false, holding fillSlide: RowFillSlide? = nil,
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
        let revealed = scrollTarget(target)
        let reveal = { KeyboardFocus.reveal(revealed, among: stops, travelling: travel) }
        if let fillSlide { fillSlide.holdInViewport(while: reveal) } else { reveal() }
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

final class ResetFlashLabel: NSTextField, ThemeReapplying {
    private var hideTimer: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = ChromeType.font(.caption, weight: .medium)
        textColor = Theme.current.chrome.positive.nsColor
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func flash(_ text: String) {
        stringValue = text
        isHidden = false
        let hide = DispatchWorkItem { [weak self] in self?.isHidden = true }
        hideTimer?.cancel()
        hideTimer = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.Linger.notice, execute: hide)
    }

    func reapplyTheme() {
        textColor = Theme.current.chrome.positive.nsColor
    }
}
