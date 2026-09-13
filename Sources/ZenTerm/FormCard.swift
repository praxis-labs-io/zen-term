import AppKit

enum FormCard {
    static let maxHeight: CGFloat = 460

    struct Content {
        let view: NSStackView
        let divider: ThemeReapplying
    }

    /// The body's fit constraint stays `.defaultLow`; higher, it squashed captions to zero at the cap.
    static func content(rows: [NSView], footer: NSView, spacing: CGFloat) -> Content {
        let body = NSStackView(views: rows)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = spacing
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in rows {
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        let scroll = SettingsDetail.scroll(for: body)
        scroll.heightAnchor.constraint(lessThanOrEqualTo: body.heightAnchor, constant: 36).isActive = true
        let fits = scroll.heightAnchor.constraint(equalTo: body.heightAnchor, constant: 36)
        fits.priority = .defaultLow
        fits.isActive = true
        body.setContentCompressionResistancePriority(.required, for: .vertical)

        let footerRow = NSView()
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: footerRow.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: footerRow.trailingAnchor, constant: -20),
            footer.topAnchor.constraint(equalTo: footerRow.topAnchor, constant: 14),
            footer.bottomAnchor.constraint(equalTo: footerRow.bottomAnchor, constant: -16),
        ])

        let divider = Hairline()

        let content = NSStackView(views: [scroll, divider, footerRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        divider.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        footerRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        return Content(view: content, divider: divider)
    }

    private final class Hairline: NSView, ThemeReapplying {
        init() {
            super.init(frame: .zero)
            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false
            heightAnchor.constraint(equalToConstant: 1).isActive = true
            reapplyTheme()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func reapplyTheme() {
            layer?.backgroundColor = Theme.current.chrome.fill(alpha: ChromeTheme.hairline).cgColor
        }
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
