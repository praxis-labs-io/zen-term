#if DEBUG
    import AppKit

    @MainActor
    enum GalleryPaneHeaders {
        private static let paneControls: [PaneHeader.Control] = [.splitHorizontal, .splitVertical, .focusMode, .close]
        private static let shell = PaneHeader.Content(process: .shell, name: "zsh", detail: "~/Dev/zen-term")

        static func sections() -> [GallerySection] {
            let hovered = header(shell)
            hovered.forceHoverForGallery()
            let zoomed = header(shell, active: true)
            zoomed.isZoomed = true
            let scrolling = header(shell, active: true)
            scrolling.modeDetail = ScrollModeController.headerTitle(nil)
            return [
                GallerySection(
                    title: "PaneHeader",
                    rows: [
                        GallerySection.Row(label: "Shell, focused", samples: [header(shell, active: true)]),
                        GallerySection.Row(label: "Unfocused", samples: [header(shell)]),
                        GallerySection.Row(label: "Unfocused, hover", samples: [hovered]),
                        GallerySection.Row(
                            label: "Program with a detail",
                            samples: [
                                header(
                                    PaneHeader.Content(
                                        process: ProcessIcon.forProgram("nvim"), name: "nvim",
                                        detail: "Sources/ZenTerm/UI/PaneHeader.swift"),
                                    active: true)
                            ]),
                        GallerySection.Row(
                            label: "Title the program sets",
                            samples: [
                                header(
                                    PaneHeader.Content(
                                        process: ProcessIcon.forAgent("claude"), name: "Pane headers", detail: nil),
                                    active: true)
                            ]),
                        GallerySection.Row(label: "Focus mode", samples: [zoomed]),
                        GallerySection.Row(label: "Scroll mode", samples: [scrolling]),
                        GallerySection.Row(
                            label: "Drawer", samples: [header(shell, controls: [.focusMode, .close], active: true)]),
                        GallerySection.Row(
                            label: "Tool float",
                            samples: [
                                header(
                                    PaneHeader.Content(process: .tool, name: "Linear", detail: "lazylinear"),
                                    controls: [.minimize, .close], active: true)
                            ]),
                        GallerySection.Row(
                            label: "Narrow pane",
                            samples: [
                                header(
                                    PaneHeader.Content(
                                        process: .shell, name: "zsh", detail: "~/Dev/zen-term/Sources/ZenTerm"),
                                    active: true, width: 200)
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
