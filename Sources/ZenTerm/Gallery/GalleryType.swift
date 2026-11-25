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
                    ]),
                GallerySection(
                    title: "BalancedLabel",
                    rows: [
                        balanced("One line", "Connecting…", ChromeType.font(.small), ink: .subtle),
                        balanced(
                            "Wrapped, balanced", "Enter the six digit code from the authenticator app on your phone",
                            ChromeType.font(.small), ink: .subtle),
                        balanced(
                            "Mono detail",
                            "Could not resolve hostname zenlab-nowhere.invalid: nodename nor servname provided",
                            ChromeType.font(.small, face: .mono), ink: .faint),
                    ]),
            ]
        }

        private static let balancedWidth: CGFloat = 360

        private static func balanced(_ label: String, _ text: String, _ font: NSFont, ink: ChromeTheme.InkLevel)
            -> GallerySection.Row
        {
            let sample = BalancedLabel(font: font, wrapWidth: balancedWidth)
            sample.stringValue = text
            sample.textColor = Theme.current.chrome.ink(ink)
            return GallerySection.Row(label: label, samples: [sample])
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
