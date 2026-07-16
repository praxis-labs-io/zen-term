import AppKit

/// The Settings card — a `ModalOverlay` like the palettes (shared card + backdrop + spring), with
/// a left nav of sections and a right detail pane. Keyboard-driven, arrows primary: Up/Down move
/// within the nav, Right/Tab enter the detail pane, Left returns to the nav, Esc closes (owned by
/// the card root — see `ModalEscape`). In the detail pane Tab/Shift-Tab advance/retreat stops,
/// wrapping forward at the last and exiting to the nav from the first. Config edits apply live.
final class SettingsOverlay: NSView, ModalOverlay {
    private let sections: [SettingsSection]
    private let capturer: KeybindCapturing?
    private let onClose: () -> Void

    private let card = CardView()
    private var dismiss = DismissGate()

    private let navStack = NSStackView()
    private let navScroll = NSScrollView()  // scrolls the nav rows when they'd overflow the column
    private var navRows: [SettingsNavRow] = []
    private let detailContainer = NSView()
    private var selectedIndex = 0
    private let heading = NSTextField(labelWithString: "Settings".uppercased())
    private let divider = NSView()
    /// Nav footer: the origami brand mark + the app version, pinned to the bottom of the nav column.
    private let brandMark = NSImageView()
    private let versionLabel = NSTextField(labelWithString: "")

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

    // MARK: ModalOverlay

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
        capturer?.endCapture()  // never leave a capture handler armed after the card closes
        Motion.springScaleFade(card, appearing: false, completion: completion)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { dismiss.isDismissing ? nil : super.hitTest(point) }

    /// The card root owns Esc: an open dropdown closes first, else the card does. Claimed here (not
    /// in `keyDown`) because `performKeyEquivalent` is the only layer that runs before a button's
    /// own `"\u{1b}"` key equivalent.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ModalEscape.handle(event, in: window, close: { self.onClose() }) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Re-apply the card's theme-dependent colors after a live theme change: the retained shell
    /// (card fill/border, heading, divider), the nav rows, and every section IN PLACE — never via
    /// `selectSection`, which would call `sectionWillHide()` on the current section even though its
    /// index didn't change. That matters across windows: a theme edit in one window fires
    /// `.configDidChange` globally, so a *different* window sitting on Keybinds with a capture armed
    /// must not have it silently cancelled by this window's theme swap. Every section (not just the
    /// visible one) is recolored — a hidden section's rows are unparented (harmless to recolor) but
    /// its persistent Reset-all button/flash must be right for when it's next shown.
    func reapplyTheme() {
        CardChrome.reapplyTheme(to: card)
        heading.textColor = Theme.current.chrome.ink(alpha: 0.4)
        divider.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        brandMark.contentTintColor = Theme.current.chrome.accent.nsColor
        versionLabel.textColor = Theme.current.chrome.ink(alpha: 0.4)
        navRows.forEach { $0.reapplyTheme() }
        sections.forEach { $0.reapplyTheme() }
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
            let row = SettingsNavRow(title: section.navTitle) { [weak self] in self?.selectSection(index) }
            row.onArrowUp = { [weak self] in self?.moveNav(-1) }
            row.onArrowDown = { [weak self] in self?.moveNav(1) }
            row.onEnterDetail = { [weak self] in self?.enterDetail() }
            navRows.append(row)
            navStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: navStack.widthAnchor, constant: -24).isActive = true
        }

        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        let footer = makeNavFooter()

        // The nav rows scroll when they'd overflow the column (many sections on a short window),
        // instead of clipping or colliding with the version footer pinned below (ZEN-136). Keyboard
        // nav scrolls the selected row into view in `selectSection`.
        navScroll.translatesAutoresizingMaskIntoConstraints = false
        // Install the flipped clip view BEFORE `drawsBackground = false`: that property forwards to
        // the scroll view's CURRENT clip view, so swapping the clip view afterwards resurrects the
        // default opaque system background — an appearance-following wash over the nav column that
        // ignores Theme.current (ZEN-27) and reads as a mismatched sidebar panel.
        navScroll.contentView = FlippedClipView()  // top-down: the list starts at the top and scrolls down
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
        root.addSubview(footer)
        root.addSubview(divider)
        root.addSubview(detailContainer)
        NSLayoutConstraint.activate([
            navScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            navScroll.topAnchor.constraint(equalTo: root.topAnchor),
            navScroll.widthAnchor.constraint(equalToConstant: 168),
            navScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            // navStack is the scrolling document: full content width, height intrinsic (scrolls tall).
            navStack.topAnchor.constraint(equalTo: navScroll.contentView.topAnchor),
            navStack.leadingAnchor.constraint(equalTo: navScroll.contentView.leadingAnchor),
            navStack.widthAnchor.constraint(equalTo: navScroll.contentView.widthAnchor),

            // The version footer sits below the scrolling list, always pinned to the column bottom.
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: navScroll.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

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

    /// The origami brand mark + "ZenTerm v<version>", sitting at the very bottom of the nav column.
    /// Informational only — non-interactive. The mark is the app icon's crane, tinted with the
    /// live accent; the label is muted like the section captions.
    private func makeNavFooter() -> NSView {
        brandMark.image = BrandMark.image("origami")
        brandMark.contentTintColor = Theme.current.chrome.accent.nsColor
        brandMark.imageScaling = .scaleProportionallyUpOrDown
        brandMark.translatesAutoresizingMaskIntoConstraints = false

        versionLabel.stringValue = "ZenTerm v\(AppVersion.current)"
        versionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        versionLabel.textColor = Theme.current.chrome.ink(alpha: 0.4)

        let stack = NSStackView(views: [brandMark, versionLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            brandMark.widthAnchor.constraint(equalToConstant: 16),
            brandMark.heightAnchor.constraint(equalToConstant: 16),
        ])
        return stack
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
        navRows[index].scrollToVisible(navRows[index].bounds)  // keep the selected row on screen when the list scrolls
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
