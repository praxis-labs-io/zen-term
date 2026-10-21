#if DEBUG
    import AppKit

    enum GalleryType {
        private static let sample = "Open a pane in 12 workspaces"

        static func sections() -> [GallerySection] {
            [
                GallerySection(
                    title: "ChromeType",
                    rows: [
                        row("Display", [ChromeType.font(.display)]),
                        row("Title", [ChromeType.font(.title)]),
                        row(
                            "Body: regular, medium, semibold",
                            [
                                ChromeType.font(.body), ChromeType.font(.body, weight: .medium),
                                ChromeType.font(.body, weight: .semibold),
                            ]),
                        row("Small", [ChromeType.font(.small)]),
                        row(
                            "Caption: regular, medium",
                            [ChromeType.font(.caption), ChromeType.font(.caption, weight: .medium)]),
                        row("Section label", [ChromeType.sectionLabel], ink: .muted),
                        row(
                            "Mono: body, small, caption",
                            [
                                ChromeType.font(.body, face: .mono), ChromeType.font(.small, face: .mono),
                                ChromeType.font(.caption, face: .mono),
                            ]),
                    ])
            ]
        }

        private static func row(_ label: String, _ fonts: [NSFont], ink: ChromeTheme.InkLevel = .normal)
            -> GallerySection.Row
        {
            GallerySection.Row(
                label: label,
                samples: fonts.map { font in
                    let text = NSTextField(labelWithString: sample)
                    text.font = font
                    text.textColor = Theme.current.chrome.ink(ink)
                    return text
                })
        }
    }
#endif
