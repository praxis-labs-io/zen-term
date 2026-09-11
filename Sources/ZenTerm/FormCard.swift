import AppKit

/// The card assembly every form overlay shares: a scrolling body with the footer pinned outside it,
/// under the same height cap the Settings card carries.
enum FormCard {
    /// Matches `SettingsOverlay`'s card, so the two read as the same size of thing. Without a cap a
    /// form grows with its content and becomes a full-height wall on a tall display.
    static let maxHeight: CGFloat = 460

    /// Wrap a form's rows in the shared card content: `rows` scroll, `footer` stays put, because a
    /// form long enough to clip is exactly the one where its buttons have to stay reachable. Pin
    /// the result to the card's edges; `spacing` is the gap between rows.
    static func content(rows: [NSView], footer: NSView, spacing: CGFloat) -> NSStackView {
        let body = NSStackView(views: rows)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = spacing
        body.translatesAutoresizingMaskIntoConstraints = false
        // Stretch every row to the content width (AppKit stacks have no `.fill` alignment).
        for view in rows {
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        let scroll = SettingsDetail.scroll(for: body)
        // `SettingsDetail.scroll` insets the body 18 top and bottom, so 36 is the body's own height
        // plus its insets. The `<=` keeps a short form from leaving dead space; the equality is
        // `.defaultLow` so a long one scrolls instead of dragging the body down with it. As a
        // two-way equality at `.defaultHigh` it outranked the labels' 750 compression resistance
        // and squashed every caption in the form to zero height once the card hit its cap.
        scroll.heightAnchor.constraint(lessThanOrEqualTo: body.heightAnchor, constant: 36).isActive = true
        let fits = scroll.heightAnchor.constraint(equalTo: body.heightAnchor, constant: 36)
        fits.priority = .defaultLow
        fits.isActive = true
        body.setContentCompressionResistancePriority(.required, for: .vertical)

        // The scroll spans the card, so the footer carries the side insets itself rather than
        // taking them from the stack (which would inset the scroll with it).
        let footerRow = NSView()
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: footerRow.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: footerRow.trailingAnchor, constant: -20),
            footer.topAnchor.constraint(equalTo: footerRow.topAnchor, constant: 14),
            footer.bottomAnchor.constraint(equalTo: footerRow.bottomAnchor, constant: -16),
        ])

        // The buttons sit against content that scrolls under them, so the band needs an edge the
        // way the palette's hint row does. Without it a clipped row reads as the footer's own.
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.current.chrome.fill(alpha: ChromeTheme.hairline).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let content = NSStackView(views: [scroll, divider, footerRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        divider.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        footerRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        return content
    }

    /// The view scrolled into view for a focus stop: its labelled group where it has one, so the
    /// inline validation message under a field arrives with it.
    static func revealTarget(for stop: NSView) -> NSView {
        var view: NSView? = stop
        while let current = view {
            if current is LabeledField { return current }
            view = current.superview
        }
        return stop
    }
}
