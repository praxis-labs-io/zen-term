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
        // `SettingsDetail.scroll` insets the body 18 top and bottom; matching that here lets a short
        // form size to its content while the cap above still wins on a long one.
        let fits = scroll.heightAnchor.constraint(equalTo: body.heightAnchor, constant: 36)
        fits.priority = .defaultHigh
        fits.isActive = true

        // The scroll spans the card, so the footer carries the side insets itself rather than
        // taking them from the stack (which would inset the scroll with it).
        let footerRow = NSView()
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: footerRow.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: footerRow.trailingAnchor, constant: -20),
            footer.topAnchor.constraint(equalTo: footerRow.topAnchor),
            footer.bottomAnchor.constraint(equalTo: footerRow.bottomAnchor, constant: -16),
        ])

        let content = NSStackView(views: [scroll, footerRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
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
