#if DEBUG
    import AppKit

    final class GallerySection: NSView {
        struct Row {
            let label: String
            let samples: [NSView]
        }

        private static let labelWidth: CGFloat = 170

        init(title: String, rows: [Row]) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            let heading = NSTextField(labelWithString: title)
            heading.font = ChromeType.font(.body, weight: .semibold)
            heading.textColor = Theme.current.chrome.ink(.normal)

            let stack = NSStackView(views: [heading] + rows.map(Self.line))
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = ChromeMetrics.Spacing.s12
            stack.setCustomSpacing(ChromeMetrics.Spacing.s16, after: heading)
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        private static func line(_ row: Row) -> NSView {
            let caption = FieldCaption(row.label, required: false)
            caption.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true

            let samples = NSStackView(views: row.samples)
            samples.orientation = .horizontal
            samples.alignment = .centerY
            samples.spacing = ChromeMetrics.Spacing.s16

            let line = NSStackView(views: [caption, samples])
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = 0
            return line
        }
    }
#endif
