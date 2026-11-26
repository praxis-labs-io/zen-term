#if DEBUG
    import AppKit

    @MainActor
    enum GalleryPaneHeaders {
        private static let paneControls: [PaneHeader.Control] = [.splitHorizontal, .splitVertical, .focusMode, .close]
        private static let shell = PaneHeader.Label(text: "~/Dev/zen-term", isPath: true)

        static func sections() -> [GallerySection] {
            let hovered = header(shell)
            hovered.forceHoverForGallery()
            let zoomed = header(shell, active: true)
            zoomed.isZoomed = true
            return [
                GallerySection(
                    title: "PaneHeader",
                    rows: [
                        GallerySection.Row(label: "Shell, focused", samples: [header(shell, active: true)]),
                        GallerySection.Row(label: "Unfocused", samples: [header(shell)]),
                        GallerySection.Row(label: "Unfocused, hover", samples: [hovered]),
                        GallerySection.Row(
                            label: "Path at rest, or under a running program",
                            samples: [
                                header(PaneHeader.Label(text: "~/Dev/zen-term/Sources", isPath: true), active: true)
                            ]),
                        GallerySection.Row(
                            label: "Title the program sets",
                            samples: [
                                header(
                                    PaneHeader.Label(text: "✳ Pane headers"),
                                    active: true)
                            ]),
                        GallerySection.Row(label: "Focus mode", samples: [zoomed]),
                        GallerySection.Row(
                            label: "Drawer", samples: [header(shell, controls: [.focusMode, .close], active: true)]),
                        GallerySection.Row(
                            label: "Tool float",
                            samples: [
                                header(
                                    PaneHeader.Label(text: "Linear"),
                                    controls: [.minimize, .close], active: true)
                            ]),
                        GallerySection.Row(
                            label: "Narrow pane",
                            samples: [
                                header(
                                    PaneHeader.Label(text: "~/Dev/zen-term/Sources/ZenTerm", isPath: true),
                                    active: true, width: 200)
                            ]),
                    ])
            ]
        }

        private static func header(
            _ label: PaneHeader.Label, controls: [PaneHeader.Control] = paneControls, active: Bool = false,
            width: CGFloat = 480
        ) -> PaneHeader {
            let header = PaneHeader(label: label, controls: controls, onControl: { _ in })
            header.isActive = active
            header.widthAnchor.constraint(equalToConstant: width).isActive = true
            return header
        }
    }
#endif
