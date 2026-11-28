import AppKit

// A small form hosted in a `ListPopover`: a header with a trailing control, a status line, captioned sections, and a checklist.
final class PopoverForm: NSView, ThemeReapplying {
    struct Header {
        let symbol: String
        let title: String
        let control: NSView
    }

    struct Section {
        let caption: String
        let control: NSView
    }

    struct ChecklistRow: Equatable {
        var title: String
        var note: String?
        var isCurrent: Bool
        var isEnabled: Bool

        init(title: String, note: String? = nil, isCurrent: Bool = false, isEnabled: Bool = true) {
            self.title = title
            self.note = note
            self.isCurrent = isCurrent
            self.isEnabled = isEnabled
        }
    }

    static let width: CGFloat = 272
    private static let headerHeight = ChromeMetrics.Height.lg
    private static let rowHeight = ChromeMetrics.Height.control
    private static let statusGap = ChromeMetrics.Spacing.s4
    private static let sectionGap = ChromeMetrics.Spacing.s12
    private static let captionGap = ChromeMetrics.Spacing.s6
    private static let textInset = ChromeMetrics.Spacing.controlInset

    private let header: Header
    private let sections: [Section]
    private let onChoose: (Int) -> Void
    private let stack = NSStackView()
    private let glyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var headerView = Self.inset(headerLine())
    private lazy var statusView = Self.inset(statusLabel)
    private let checklistCaption: SectionCaption
    private lazy var checklistCaptionView = Self.inset(checklistCaption)
    private(set) var rows: [ChecklistRow] = []
    private var rowViews: [ListRow] = []

    var highlightedRow: Int? {
        didSet { refreshHighlight() }
    }

    var status: String? { statusView.isHidden ? nil : statusLabel.stringValue }
    var rowViewsForTesting: [ListRow] { rowViews }

    init(
        header: Header, status: String?, sections: [Section], checklistCaption: String, rows: [ChecklistRow],
        onChoose: @escaping (Int) -> Void
    ) {
        self.header = header
        self.sections = sections
        self.checklistCaption = SectionCaption(checklistCaption)
        self.onChoose = onChoose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        titleLabel.font = ChromeType.font(.body, weight: .semibold)
        titleLabel.stringValue = header.title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        glyph.image = IconCatalog.image(header.symbol, pointSize: ChromeMetrics.Icon.md, weight: .regular)
        statusLabel.font = ChromeType.font(.small)
        statusLabel.preferredMaxLayoutWidth = Self.width - Self.textInset * 2

        headerView.heightAnchor.constraint(equalToConstant: Self.headerHeight).isActive = true
        stack.addArrangedSubview(headerView)
        stack.addArrangedSubview(statusView)
        stack.setCustomSpacing(Self.sectionGap, after: statusView)
        for section in sections {
            let caption = Self.inset(SectionCaption(section.caption))
            stack.addArrangedSubview(caption)
            stack.setCustomSpacing(Self.captionGap, after: caption)
            let control = Self.inset(NSStackView.huggingRow(section.control))
            stack.addArrangedSubview(control)
            stack.setCustomSpacing(Self.sectionGap, after: control)
        }
        stack.addArrangedSubview(checklistCaptionView)
        stack.setCustomSpacing(Self.captionGap, after: checklistCaptionView)

        apply(status: status, rows: rows)
        highlightedRow = rows.firstIndex { $0.isCurrent && $0.isEnabled }
        refreshHighlight()
        reapplyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func render(status: String?, rows: [ChecklistRow], in popover: ListPopover? = nil) {
        layoutSubtreeIfNeeded()
        let before = fittingSize.height
        apply(status: status, rows: rows)
        layoutSubtreeIfNeeded()
        guard let popover, popover.isOpen, fittingSize.height != before else { return }
        let focused = (window?.firstResponder as? NSView).flatMap { $0.isDescendant(of: self) ? $0 : nil }
        popover.replace(content: self)
        window?.makeFirstResponder(focused ?? self)
    }

    func takeFocus() { window?.makeFirstResponder(self) }

    func reapplyTheme() {
        let chrome = Theme.current.chrome
        glyph.contentTintColor = chrome.ink(.subtle)
        titleLabel.textColor = chrome.ink(.normal)
        statusLabel.textColor = chrome.ink(.muted)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(for: event) {
        case .up: moveHighlight(-1)
        case .down: moveHighlight(1)
        case .activate: if let highlightedRow { choose(highlightedRow) }
        case .tab(let shift): moveFocus(shift ? -1 : 1)
        default: super.keyDown(with: event)
        }
    }

    private func apply(status: String?, rows: [ChecklistRow]) {
        statusLabel.stringValue = status ?? ""
        statusView.isHidden = status == nil
        stack.setCustomSpacing(status == nil ? Self.sectionGap : Self.statusGap, after: headerView)

        if rows.count != rowViews.count { rebuildRows(count: rows.count) }
        self.rows = rows
        for (row, view) in zip(rows, rowViews) { view.render(Self.content(row)) }
        if let highlightedRow, !rows.indices.contains(highlightedRow) || !rows[highlightedRow].isEnabled {
            self.highlightedRow = nil
        }
    }

    private func rebuildRows(count: Int) {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = (0..<count).map { index in
            let row = ListRow(ListRow.Content(title: "")) { [weak self] in self?.choose(index) }
            row.onPointerEnter = { [weak self] in self?.highlightPointed(index) }
            return row
        }
        for row in rowViews {
            stack.addArrangedSubview(row)
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        }
        refreshHighlight()
    }

    private static func content(_ row: ChecklistRow) -> ListRow.Content {
        ListRow.Content(
            title: row.title, note: row.note, trailing: row.isCurrent ? .check : nil,
            ink: row.isEnabled ? .normal : .faint)
    }

    private func choose(_ index: Int) {
        guard rows.indices.contains(index), rows[index].isEnabled else { return }
        highlightedRow = index
        onChoose(index)
    }

    private func highlightPointed(_ index: Int) {
        guard rows.indices.contains(index), rows[index].isEnabled else { return }
        highlightedRow = index
    }

    private func moveHighlight(_ delta: Int) {
        let enabled = rows.indices.filter { rows[$0].isEnabled }
        guard
            let next = KeyboardFocus.step(
                from: highlightedRow.flatMap(enabled.firstIndex(of:)), delta: delta, count: enabled.count)
        else { return }
        highlightedRow = enabled[next]
    }

    private func refreshHighlight() {
        for (index, view) in rowViews.enumerated() { view.isHighlighted = index == highlightedRow }
    }

    private var focusStops: [NSView] {
        ([header.control] + sections.map(\.control)).filter(\.acceptsFirstResponder) + [self]
    }

    private func moveFocus(_ delta: Int) {
        let stops = focusStops
        let responder = window?.firstResponder as? NSView
        let current = stops.firstIndex { stop in
            guard let responder else { return false }
            return stop === self ? responder === self : responder.isDescendant(of: stop)
        }
        guard let next = KeyboardFocus.step(from: current, delta: delta, count: stops.count, wrap: true) else { return }
        window?.makeFirstResponder(stops[next])
    }

    private func headerLine() -> NSView {
        let line = NSStackView(views: [glyph, titleLabel, header.control])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = ChromeMetrics.Spacing.s8
        line.setHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.control.setContentHuggingPriority(.required, for: .horizontal)
        return line
    }

    private static func inset(_ view: NSView) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: textInset),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -textInset),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
    }
}
