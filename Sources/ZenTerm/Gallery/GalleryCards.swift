#if DEBUG
    import AppKit

    enum GalleryCards {
        private static let variants: [(ToastVariant, String)] = [
            (.info, "Info"), (.positive, "Positive"), (.warning, "Warning"), (.destructive, "Destructive"),
        ]

        static func sections() -> [GallerySection] {
            [cards(), modalParts(), toasts(), hoverCards()]
        }

        private static func cards() -> GallerySection {
            GallerySection(
                title: "CardChrome",
                rows: [
                    GallerySection.Row(label: "Plain edge", samples: [card(focusBorder: false)]),
                    GallerySection.Row(label: "Focus border", samples: [card(focusBorder: true)]),
                ])
        }

        private static func modalParts() -> GallerySection {
            GallerySection(
                title: "ModalHeader and ModalActionBar",
                rows: [
                    GallerySection.Row(label: "Header", samples: [sized(ModalHeader(title: "Report an Issue"))]),
                    GallerySection.Row(
                        label: "Header with accessory",
                        samples: [
                            sized(ModalHeader(title: "Add Workspace", accessory: KeycapView(shortcut: "esc")))
                        ]),
                    GallerySection.Row(
                        label: "Bar",
                        samples: [
                            sized(
                                ModalActionBar(trailing: [
                                    AppButton(title: "Cancel", variant: .secondary),
                                    AppButton(title: "Create", variant: .primary),
                                ]))
                        ]),
                    GallerySection.Row(
                        label: "Bar with destructive",
                        samples: [
                            sized(
                                ModalActionBar(
                                    leading: [AppButton(title: "Delete", variant: .destructive)],
                                    trailing: [
                                        AppButton(title: "Cancel", variant: .secondary),
                                        AppButton(title: "Save", variant: .primary),
                                    ]))
                        ]),
                    GallerySection.Row(
                        label: "Bar with notice",
                        samples: [
                            sized(
                                ModalActionBar(
                                    leading: [
                                        modalNotice("Folder moved"), AppButton(title: "Undo", variant: .secondary),
                                    ],
                                    trailing: [
                                        AppButton(title: "Cancel", variant: .secondary),
                                        AppButton(title: "Add", variant: .primary),
                                    ]))
                        ]),
                ])
        }

        private static func sized(_ view: NSView) -> NSView {
            view.widthAnchor.constraint(equalToConstant: ConfirmCard.width).isActive = true
            return view
        }

        private static func modalNotice(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = ChromeType.font(.small)
            label.textColor = Theme.current.chrome.ink(.subtle)
            return label
        }

        private static let sampleSize = NSSize(width: 220, height: 80)

        private static func card(focusBorder: Bool) -> NSView {
            let card = CardView()
            card.translatesAutoresizingMaskIntoConstraints = false
            CardChrome.apply(to: card, focusBorder: focusBorder)
            NSLayoutConstraint.activate([
                card.widthAnchor.constraint(equalToConstant: Self.sampleSize.width),
                card.heightAnchor.constraint(equalToConstant: Self.sampleSize.height),
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
