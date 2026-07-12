import AppKit

/// The Settings card — a `ModalOverlay` like the palettes (shared card + backdrop + spring), with
/// a left nav of sections and a right detail pane. Keyboard-driven, arrows primary: Up/Down move
/// within the nav (and Tab/Shift-Tab advance/retreat rows in the detail pane), Right/Tab enter the
/// detail pane, Left returns to the nav, Esc closes. Config edits in each section apply live.
final class SettingsOverlay: NSView, ModalOverlay {
    private let sections: [SettingsSection]
    private let capturer: KeybindCapturing?
    private let onClose: () -> Void

    private let card = CardView()
    private var isDismissing = false

    private let navStack = NSStackView()
    private var navRows: [SettingsNavRow] = []
    private let detailContainer = NSView()
    private var selectedIndex = 0
    private let heading = NSTextField(labelWithString: "Settings".uppercased())
    private let divider = NSView()

    init(
        sections: [SettingsSection], capturer: KeybindCapturing?, background: NSColor,
        onClose: @escaping () -> Void
    ) {
        self.sections = sections
        self.capturer = capturer
        self.onClose = onClose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let backdrop = BackdropView(onClick: onClose)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = background.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = FloatShadow.edge.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        FloatShadow.applyShadow(to: card)

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

        selectSection(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: ModalOverlay

    func focusInitialResponder() {
        if let first = navRows.first { window?.makeFirstResponder(first) }
    }
    func animateIn() {
        superview?.layoutSubtreeIfNeeded()
        Motion.springScaleFade(card, appearing: true)
    }
    func animateOut(completion: @escaping () -> Void) {
        guard !isDismissing else { return }
        isDismissing = true
        capturer?.endCapture()  // never leave a capture handler armed after the card closes
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { isDismissing ? nil : super.hitTest(point) }

    /// Re-apply the card's theme-dependent colors after a live theme change: the retained shell
    /// (card fill/border, heading, divider), the nav rows, and a full detail-pane rebuild so every
    /// row/label/control inside it is reconstructed against the new theme.
    func reapplyTheme() {
        card.layer?.backgroundColor = Theme.current.chrome.background.nsColor.cgColor
        card.layer?.borderColor = FloatShadow.edge.cgColor
        heading.textColor = Theme.current.chrome.ink(alpha: 0.4)
        divider.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        navRows.forEach { $0.reapplyTheme() }
        selectSection(selectedIndex)
    }

    // MARK: content

    private func buildContent() -> NSView {
        navStack.orientation = .vertical
        navStack.alignment = .leading
        navStack.spacing = 2
        navStack.edgeInsets = NSEdgeInsets(top: 18, left: 12, bottom: 16, right: 12)

        // Top-level "SETTINGS" heading, styled like the detail pane's section captions. Wrapped so
        // its text is inset the same 10pt as the nav rows' labels, keeping them left-aligned.
        heading.font = .systemFont(ofSize: 10, weight: .semibold)
        heading.textColor = Theme.current.chrome.ink(alpha: 0.4)
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
            section.onClose = { [weak self] in self?.onClose() }
            let row = SettingsNavRow(title: section.navTitle) { [weak self] in self?.selectSection(index) }
            row.onArrowUp = { [weak self] in self?.moveNav(-1) }
            row.onArrowDown = { [weak self] in self?.moveNav(1) }
            row.onEnterDetail = { [weak self] in self?.enterDetail() }
            row.onEsc = { [weak self] in self?.onClose() }
            navRows.append(row)
            navStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: navStack.widthAnchor, constant: -24).isActive = true
        }

        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        navStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(navStack)
        root.addSubview(divider)
        root.addSubview(detailContainer)
        NSLayoutConstraint.activate([
            navStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            navStack.topAnchor.constraint(equalTo: root.topAnchor),
            navStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            navStack.widthAnchor.constraint(equalToConstant: 168),

            divider.leadingAnchor.constraint(equalTo: navStack.trailingAnchor),
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

    // MARK: selection + focus

    private func selectSection(_ index: Int) {
        guard sections.indices.contains(index) else { return }
        // Let the outgoing section end any in-flight interaction (e.g. an armed keybind capture)
        // before its detail view — and any capture backdrop/popover on it — is removed.
        if sections.indices.contains(selectedIndex) { sections[selectedIndex].sectionWillHide() }
        selectedIndex = index
        for (rowIndex, row) in navRows.enumerated() { row.setSelected(rowIndex == index) }
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        let detail = sections[index].makeDetailView()
        detail.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detail)
        // The section fills the detail area edge-to-edge (no outer gap); a scrolling section owns its
        // own inner padding via content insets, so its list can scroll right up to the card edges.
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            detail.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detail.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
        window?.makeFirstResponder(navRows[index])
    }

    private func moveNav(_ delta: Int) {
        let current = navRows.firstIndex { KeyboardFocus.isFocused($0, in: window) }
        guard let next = KeyboardFocus.step(from: current, delta: delta, count: navRows.count) else { return }
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
}
