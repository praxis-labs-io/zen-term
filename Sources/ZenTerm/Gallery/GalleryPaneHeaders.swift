#if DEBUG
    import AppKit

    @MainActor
    enum GalleryPaneHeaders {
        private static let paneControls: [PaneHeader.Control] = [.splitHorizontal, .splitVertical, .focusMode, .close]
        private static let shell = PaneHeader.Content(process: .shell, name: "zsh", path: "~/dev/zen-term")

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
                            label: "Program",
                            samples: [
                                header(
                                    PaneHeader.Content(
                                        process: ProcessIcon.forProgram("nvim"), name: "nvim", path: "~/dev/zen-term"),
                                    active: true)
                            ]),
                        GallerySection.Row(
                            label: "Agent",
                            samples: [
                                header(
                                    PaneHeader.Content(
                                        process: ProcessIcon.forAgent("claude"), name: "Claude Code",
                                        path: "~/dev/zen-term"),
                                    active: true)
                            ]),
                        GallerySection.Row(label: "Focus mode", samples: [zoomed]),
                        GallerySection.Row(
                            label: "Drawer", samples: [header(shell, controls: [.focusMode, .close], active: true)]),
                        GallerySection.Row(
                            label: "Tool float",
                            samples: [
                                header(
                                    PaneHeader.Content(process: .tool, name: "Zen Octo", path: nil),
                                    controls: [.minimize, .end], active: true)
                            ]),
                        GallerySection.Row(
                            label: "Narrow pane",
                            samples: [
                                header(
                                    PaneHeader.Content(
                                        process: .shell, name: "zsh", path: "~/dev/zen-term/Sources/ZenTerm/UI"),
                                    active: true, width: 220)
                            ]),
                    ])
            ]
        }

        private static func header(
            _ content: PaneHeader.Content, controls: [PaneHeader.Control] = paneControls, active: Bool = false,
            width: CGFloat = 480
        ) -> PaneHeader {
            let header = PaneHeader(content: content, controls: controls, onControl: { _ in })
            header.isActive = active
            header.widthAnchor.constraint(equalToConstant: width).isActive = true
            return header
        }
    }
#endif
