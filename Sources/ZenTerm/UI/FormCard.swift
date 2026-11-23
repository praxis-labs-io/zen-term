import AppKit

enum FormCard {
    static let maxHeight: CGFloat = 460

    /// The body's fit constraint stays `.defaultLow`; higher, it squashed captions to zero at the cap.
    static func content(rows: [NSView], footer: NSView, spacing: CGFloat) -> NSStackView {
        let body = NSStackView(views: rows)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = spacing
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in rows {
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        let scroll = SettingsDetail.scroll(for: body)
        scroll.heightAnchor.constraint(
            lessThanOrEqualTo: body.heightAnchor,
            constant: ChromeMetrics.Spacing.modalInsets.top + ChromeMetrics.Spacing.modalInsets.bottom
        ).isActive = true
        let fits = scroll.heightAnchor.constraint(
            equalTo: body.heightAnchor,
            constant: ChromeMetrics.Spacing.modalInsets.top + ChromeMetrics.Spacing.modalInsets.bottom)
        fits.priority = .defaultLow
        fits.isActive = true
        body.setContentCompressionResistancePriority(.required, for: .vertical)

        let footerRow = NSView()
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(
                equalTo: footerRow.leadingAnchor, constant: ChromeMetrics.Spacing.modalInsets.left),
            footer.trailingAnchor.constraint(
                equalTo: footerRow.trailingAnchor, constant: -ChromeMetrics.Spacing.modalInsets.right),
            footer.topAnchor.constraint(equalTo: footerRow.topAnchor, constant: ChromeMetrics.Spacing.modalInsets.top),
            footer.bottomAnchor.constraint(
                equalTo: footerRow.bottomAnchor, constant: -ChromeMetrics.Spacing.modalInsets.bottom),
        ])

        let divider = Divider()

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

    static func footer(_ actions: ModalActionBar, failure: FormErrorLabel) -> NSStackView {
        let stack = NSStackView(views: [failure, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ChromeMetrics.Spacing.s10
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    static func revealTarget(for stop: NSView) -> NSView {
        var view: NSView? = stop
        while let current = view {
            if current is LabeledField { return current }
            view = current.superview
        }
        return stop
    }
}
