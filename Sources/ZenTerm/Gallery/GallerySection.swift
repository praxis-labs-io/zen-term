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

            let lines = rows.map(Self.line)
            let stack = NSStackView(views: [heading] + lines)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = ChromeMetrics.Spacing.s12
            stack.setCustomSpacing(ChromeMetrics.Spacing.s16, after: heading)
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            NSLayoutConstraint.activate(lines.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        private static func line(_ row: Row) -> NSView {
            let caption = SectionCaption(row.label)
            let samples = GallerySamples(row.samples)

            let line = NSView()
            line.translatesAutoresizingMaskIntoConstraints = false
            line.addSubview(caption)
            line.addSubview(samples)
            NSLayoutConstraint.activate([
                caption.leadingAnchor.constraint(equalTo: line.leadingAnchor),
                caption.widthAnchor.constraint(equalToConstant: labelWidth),
                caption.centerYAnchor.constraint(equalTo: samples.firstLine.centerYAnchor),
                samples.firstLine.heightAnchor.constraint(greaterThanOrEqualTo: caption.heightAnchor),
                samples.leadingAnchor.constraint(equalTo: caption.trailingAnchor),
                samples.trailingAnchor.constraint(equalTo: line.trailingAnchor),
                samples.topAnchor.constraint(equalTo: line.topAnchor),
                samples.bottomAnchor.constraint(equalTo: line.bottomAnchor),
            ])
            return line
        }
    }
#endif
