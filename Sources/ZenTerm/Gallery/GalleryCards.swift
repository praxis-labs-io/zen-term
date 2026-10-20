#if DEBUG
    import AppKit

    enum GalleryCards {
        private static let variants: [(ToastVariant, String)] = [
            (.info, "Info"), (.positive, "Positive"), (.warning, "Warning"), (.destructive, "Destructive"),
        ]

        static func sections() -> [GallerySection] {
            [cards(), toasts(), hoverCards()]
        }

        private static func cards() -> GallerySection {
            GallerySection(
                title: "CardChrome",
                rows: [
                    GallerySection.Row(label: "Plain edge", samples: [card(halo: false)]),
                    GallerySection.Row(label: "Halo edge", samples: [card(halo: true)]),
                ])
        }

        private static func card(halo: Bool) -> NSView {
            let card = CardView()
            card.translatesAutoresizingMaskIntoConstraints = false
            CardChrome.apply(to: card, background: Theme.current.chrome.background.nsColor, halo: halo)
            NSLayoutConstraint.activate([
                card.widthAnchor.constraint(equalToConstant: 220),
                card.heightAnchor.constraint(equalToConstant: 80),
            ])
            return card
        }

        private static func toasts() -> GallerySection {
            var rows = variants.map { variant, name in
                GallerySection.Row(
                    label: name,
                    samples: [
                        toast(ToastContent(variant: variant, title: "Title only", message: nil)),
                        toast(
                            ToastContent(
                                variant: variant, title: "With message",
                                message: "Config reloaded with 2 changes. Open panes keep their font size.")),
                    ])
            }
            rows += [
                GallerySection.Row(
                    label: "Title tail",
                    samples: [
                        toast(
                            ToastContent(
                                variant: .positive, title: "Created worktree ", titleTail: "feature/long-branch-name",
                                message: nil))
                    ]),
                GallerySection.Row(
                    label: "Actions",
                    samples: [
                        toast(
                            ToastContent(
                                variant: .warning, title: "Remove worktree?",
                                message: "Uncommitted changes in 3 files are lost."),
                            actions: [
                                ToastAction(title: "Cancel", kind: .cancel, shortcut: { "esc" }) {},
                                ToastAction(title: "Remove", kind: .destructive, shortcut: { "⏎" }) {},
                            ]),
                        toast(
                            ToastContent(variant: .info, title: "Update ready", message: "Version 1.9.0 is ready."),
                            actions: [ToastAction(title: "Restart", kind: .primary) {}]),
                    ]),
                GallerySection.Row(
                    label: "Close button",
                    samples: [
                        toast(
                            ToastContent(variant: .info, title: "Close button", message: "Stays until dismissed."),
                            showsClose: true)
                    ]),
            ]
            return GallerySection(title: "ToastView", rows: rows)
        }

        private static func toast(
            _ content: ToastContent, actions: [ToastAction] = [], showsClose: Bool = false
        ) -> ToastView {
            ToastView(content: content, actions: actions, armsKeys: false, showsClose: showsClose)
        }

        private static func hoverCards() -> GallerySection {
            GallerySection(
                title: "HoverCardView",
                rows: [
                    GallerySection.Row(
                        label: "Tooltip line", samples: [ChromeTooltip(label: "New tab", shortcut: nil)]),
                    GallerySection.Row(
                        label: "Tooltip with shortcut", samples: [ChromeTooltip(label: "New tab", shortcut: "⌘T")]),
                    GallerySection.Row(
                        label: "Tooltip paragraph",
                        samples: [
                            ChromeTooltip(
                                label:
                                    "Opens the workspace with this pane focused, so the cursor lands where you left it.",
                                shortcut: nil, style: .paragraph)
                        ]),
                    GallerySection.Row(
                        label: "Link preview",
                        samples: [LinkPreviewView(url: "https://example.com/docs/config/general#window-chrome")]),
                ])
        }
    }
#endif
