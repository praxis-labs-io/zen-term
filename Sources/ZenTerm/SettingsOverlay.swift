import AppKit

final class SettingsOverlay: NSView, ModalOverlay {
    private let sections: [SettingsSection]
    private let capturer: KeybindCapturing?
    private let onClose: () -> Void

    private let card = CardView()
    private var dismiss = DismissGate()

    private let navStack = NSStackView()
    private let navScroll = FadingScrollView()
    private var navRows: [SettingsNavRow] = []
    private let detailContainer = NSView()
    private var selectedIndex = 0
    private let heading = NSTextField(labelWithString: "Settings".uppercased())
    private let divider = NSView()
    private let brandMark = NSImageView()
    private let versionLabel = NSTextField(labelWithString: "")
    private let reportButton = AppButton(title: "Report an Issue", variant: .link)
    var onReportIssue: (() -> Void)?

    init(
        sections: [SettingsSection], capturer: KeybindCapturing?, initialSection: Int = 0,
        background: NSColor, onClose: @escaping () -> Void
    ) {
        self.sections = sections
        self.capturer = capturer
        self.onClose = onClose
        self.selectedIndex = sections.indices.contains(initialSection) ? initialSection : 0
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let backdrop = BackdropView(onClick: onClose)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        CardChrome.apply(to: card, background: background)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let content = buildContent()
        card.addSubview(content)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 620),
            card.heightAnchor.constraint(equalToConstant: 460),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.92),
            card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.92),

            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        selectSection(selectedIndex)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func focusInitialResponder() {
        guard navRows.indices.contains(selectedIndex) else { return }
        window?.makeFirstResponder(navRows[selectedIndex])
    }
    func animateIn() {
        superview?.layoutSubtreeIfNeeded()
        Motion.springScaleFade(card, appearing: true)
    }
    func animateOut(completion: @escaping () -> Void) {
        guard dismiss.begin() else { return }
        capturer?.endCapture()
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { dismiss.isDismissing ? nil : super.hitTest(point) }

    // Here, not `keyDown`, so Esc from a focused text field's field editor still closes the card.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ModalEscape.handle(
            event, in: window, dismissing: dismiss.isDismissing, close: { self.onClose() }
        ) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // In place, not via `selectSection`, which would cancel another window's armed keybind capture.
    func reapplyTheme() {
        CardChrome.reapplyTheme(to: card)
        heading.textColor = Theme.current.chrome.ink(.muted)
        divider.layer?.backgroundColor = Theme.current.chrome.fill(alpha: ChromeTheme.hairline).cgColor
        brandMark.contentTintColor = Theme.current.chrome.accent.nsColor
        versionLabel.textColor = Theme.current.chrome.ink(.muted)
        reportButton.reapplyTheme()
        navRows.forEach { $0.reapplyTheme() }
        sections.forEach { $0.reapplyTheme() }
    }

    // The clip view goes in before `drawsBackground = false`, which only applies to the current clip view.
    private func buildContent() -> NSView {
        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 2
        navStack.edgeInsets = NSEdgeInsets(top: 18, left: 12, bottom: 16, right: 12)

        heading.font = .systemFont(ofSize: 10, weight: .semibold)
        heading.textColor = Theme.current.chrome.ink(.muted)
        heading.translatesAutoresizingMaskIntoConstraints = false
        let headingRow = NSView()
        headingRow.translatesAutoresizingMaskIntoConstraints = false
        headingRow.addSubview(heading)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: headingRow.leadingAnchor, constant: 10),
            heading.trailingAnchor.constraint(equalTo: headingRow.trailingAnchor),
            heading.topAnchor.constraint(equalTo: headingRow.topAnchor),
            heading.bottomAnchor.constraint(equalTo: headingRow.bottomAnchor),
        ])
        navStack.addArrangedSubview(headingRow)
        navStack.setCustomSpacing(10, after: headingRow)

        for (index, section) in sections.enumerated() {
            section.onExitToNav = { [weak self] in self?.focusNav() }
            let row = SettingsNavRow(title: section.navTitle) { [weak self] in self?.selectSection(index) }
            row.onArrowUp = { [weak self] in self?.moveNav(-1) }
            row.onArrowDown = { [weak self] in self?.moveNav(1) }
            row.onBacktab = { [weak self] in self?.moveNav(-1, wrap: true) }
            row.onEnterDetail = { [weak self] in self?.enterDetail() }
            navRows.append(row)
            navStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: navStack.widthAnchor, constant: -24).isActive = true
        }

        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.current.chrome.fill(alpha: ChromeTheme.hairline).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        let footer = makeNavFooter()

        reportButton.isKeyboardFocusable = true
        reportButton.onTap = { [weak self] in self?.onReportIssue?() }
        reportButton.onArrowUp = { [weak self] in self?.focusNavTail() }
        reportButton.onBacktab = { [weak self] in self?.focusNavTail() }
        reportButton.translatesAutoresizingMaskIntoConstraints = false
        navRows.last?.onArrowDown = { [weak self] in self?.focusReportButton() }

        navScroll.translatesAutoresizingMaskIntoConstraints = false
        navScroll.contentView = FlippedClipView()
        navScroll.drawsBackground = false
        navScroll.borderType = .noBorder
        navScroll.hasVerticalScroller = true
        navScroll.autohidesScrollers = true
        navScroll.scrollerStyle = .overlay
        navScroll.documentView = navStack
        navStack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(navScroll)
        root.addSubview(reportButton)
        root.addSubview(footer)
        root.addSubview(divider)
        root.addSubview(detailContainer)
        NSLayoutConstraint.activate([
            navScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            navScroll.topAnchor.constraint(equalTo: root.topAnchor),
            navScroll.widthAnchor.constraint(equalToConstant: Self.navWidth),
            navScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            reportButton.centerXAnchor.constraint(equalTo: navScroll.centerXAnchor),
            reportButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: root.leadingAnchor, constant: Self.footerTrailingInset),
            reportButton.trailingAnchor.constraint(
                lessThanOrEqualTo: navScroll.trailingAnchor, constant: -Self.footerTrailingInset),
            reportButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),

            navStack.topAnchor.constraint(equalTo: navScroll.contentView.topAnchor),
            navStack.leadingAnchor.constraint(equalTo: navScroll.contentView.leadingAnchor),
            navStack.widthAnchor.constraint(equalTo: navScroll.contentView.widthAnchor),

            footer.centerXAnchor.constraint(equalTo: navScroll.centerXAnchor),
            footer.leadingAnchor.constraint(
                greaterThanOrEqualTo: root.leadingAnchor, constant: Self.footerTrailingInset),
            footer.trailingAnchor.constraint(
                lessThanOrEqualTo: navScroll.trailingAnchor, constant: -Self.footerTrailingInset),
            footer.bottomAnchor.constraint(equalTo: reportButton.topAnchor, constant: -6),

            divider.leadingAnchor.constraint(equalTo: navScroll.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            detailContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detailContainer.topAnchor.constraint(equalTo: root.topAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func makeNavFooter() -> NSView {
        brandMark.image = BrandMark.image("origami")
        brandMark.contentTintColor = Theme.current.chrome.accent.nsColor
        brandMark.imageScaling = .scaleProportionallyUpOrDown
        brandMark.translatesAutoresizingMaskIntoConstraints = false

        versionLabel.stringValue = Self.versionText
        versionLabel.font = Self.versionFont
        versionLabel.textColor = Theme.current.chrome.ink(.muted)
        versionLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [brandMark, versionLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Self.footerSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            brandMark.widthAnchor.constraint(equalToConstant: Self.brandMarkSize),
            brandMark.heightAnchor.constraint(equalToConstant: Self.brandMarkSize),
            versionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.versionMaxWidth),
        ])
        return stack
    }

    static var versionText: String { "v\(AppVersion.current)" }
    static let versionFont: NSFont = .systemFont(ofSize: 13, weight: .medium)
    private static let brandMarkSize: CGFloat = 16
    private static let footerSpacing: CGFloat = 7
    private static let navWidth: CGFloat = 168
    private static let footerTrailingInset: CGFloat = 12
    static var versionMaxWidth: CGFloat {
        navWidth - footerTrailingInset * 2 - brandMarkSize - footerSpacing
    }

    private func selectSection(_ index: Int) {
        guard sections.indices.contains(index) else { return }
        if sections.indices.contains(selectedIndex) { sections[selectedIndex].sectionWillHide() }
        selectedIndex = index
        for (rowIndex, row) in navRows.enumerated() { row.setSelected(rowIndex == index) }
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        let detail = sections[index].makeDetailView()
        detail.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detail)
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            detail.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detail.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
        window?.makeFirstResponder(navRows[index])
        navRows[index].scrollToVisible(navRows[index].bounds)
    }

    private func moveNav(_ delta: Int, wrap: Bool = false) {
        let current = navRows.firstIndex { KeyboardFocus.isFocused($0, in: window) }
        guard let next = KeyboardFocus.step(from: current, delta: delta, count: navRows.count, wrap: wrap)
        else { return }
        selectSection(next)
    }

    private func enterDetail() {
        guard let first = sections[selectedIndex].detailStops().first else { return }
        window?.makeFirstResponder(first)
    }

    private func focusNav() {
        guard navRows.indices.contains(selectedIndex) else { return }
        window?.makeFirstResponder(navRows[selectedIndex])
    }

    private func focusReportButton() { window?.makeFirstResponder(reportButton) }

    private func focusNavTail() { window?.makeFirstResponder(navRows.last) }
}
