#if DEBUG
    import AppKit

    // A gallery row's samples, left to right, wrapping onto a new line wherever the row's width runs out.
    final class GallerySamples: NSView {
        private static let spacing = ChromeMetrics.Spacing.s16
        private static let lineSpacing = ChromeMetrics.Spacing.s12

        let firstLine = NSLayoutGuide()
        private let samples: [NSView]
        private var lines: [NSLayoutGuide] = []
        private var placement: [NSLayoutConstraint] = []
        private var placedWidth: CGFloat?

        init(_ samples: [NSView]) {
            self.samples = samples
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            addLayoutGuide(firstLine)
            NSLayoutConstraint.activate([
                firstLine.leadingAnchor.constraint(equalTo: leadingAnchor),
                firstLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            for sample in samples {
                sample.translatesAutoresizingMaskIntoConstraints = false
                addSubview(sample)
            }
            place(within: 0)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        // Constraints swapped inside setFrameSize land a layout pass late, so the row's height trails its width.
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if newSize.width != placedWidth { needsUpdateConstraints = true }
        }

        override func updateConstraints() {
            if bounds.width != placedWidth { place(within: bounds.width) }
            super.updateConstraints()
        }

        var lineCountForTesting: Int { lines.count }

        private func place(within width: CGFloat) {
            placedWidth = width
            NSLayoutConstraint.deactivate(placement)
            lines.forEach(removeLayoutGuide)
            lines = []
            placement = []
            var line = startLine()
            var x: CGFloat = 0
            for sample in samples {
                let sampleWidth = sample.fittingSize.width
                if x > 0, x + sampleWidth > width {
                    line = startLine()
                    x = 0
                }
                placement += [
                    sample.leadingAnchor.constraint(equalTo: leadingAnchor, constant: x),
                    sample.centerYAnchor.constraint(equalTo: line.centerYAnchor),
                    line.heightAnchor.constraint(greaterThanOrEqualTo: sample.heightAnchor),
                ]
                x += sampleWidth + Self.spacing
            }
            placement += [
                firstLine.topAnchor.constraint(equalTo: lines[0].topAnchor),
                firstLine.heightAnchor.constraint(equalTo: lines[0].heightAnchor),
                bottomAnchor.constraint(equalTo: line.bottomAnchor),
            ]
            NSLayoutConstraint.activate(placement)
        }

        private func startLine() -> NSLayoutGuide {
            let line = NSLayoutGuide()
            addLayoutGuide(line)
            let snug = line.heightAnchor.constraint(equalToConstant: 0)
            snug.priority = .defaultLow
            placement += [
                line.topAnchor.constraint(
                    equalTo: lines.last?.bottomAnchor ?? topAnchor, constant: lines.isEmpty ? 0 : Self.lineSpacing),
                line.leadingAnchor.constraint(equalTo: leadingAnchor),
                line.trailingAnchor.constraint(equalTo: trailingAnchor),
                snug,
            ]
            lines.append(line)
            return line
        }
    }
#endif
