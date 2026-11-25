#if DEBUG
    import AppKit

    enum GalleryCards {
        static func sections() -> [GallerySection] {
            [cards(), modalParts(), toastStack(), hoverCards(), dividersAndEmptyStates()]
        }

        private static func cards() -> GallerySection {
            GallerySection(
                title: "CardChrome",
                rows: [
                    GallerySection.Row(label: "Edge and shadow", samples: [card()])
                ])
        }

        private static func modalParts() -> GallerySection {
            GallerySection(
                title: "ModalHeader and ModalActionBar",
                rows: [
                    GallerySection.Row(label: "Header", samples: [sized(ModalHeader(title: "Report an Issue"))]),
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

        private static func dividersAndEmptyStates() -> GallerySection {
            let vertical = Divider(.vertical)
            vertical.heightAnchor.constraint(equalToConstant: sampleSize.height).isActive = true
            return GallerySection(
                title: "Divider and EmptyStateLabel",
                rows: [
                    GallerySection.Row(label: "Horizontal", samples: [sized(Divider())]),
                    GallerySection.Row(label: "Vertical", samples: [vertical]),
                    GallerySection.Row(
                        label: "Empty state",
                        samples: [
                            sized(
                                EmptyStateLabel(
                                    "No workspaces yet. Add one to launch a folder with its own layout from ⌘P."))
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

        private static func card() -> NSView {
            let card = CardView()
            card.translatesAutoresizingMaskIntoConstraints = false
            CardChrome.apply(to: card)
            NSLayoutConstraint.activate([
                card.widthAnchor.constraint(equalToConstant: Self.sampleSize.width),
                card.heightAnchor.constraint(equalToConstant: Self.sampleSize.height),
            ])
            return card
        }

        private static func toastStack() -> GallerySection {
            GallerySection(
                title: "ToastPile",
                rows: [
                    GallerySection.Row(label: "Folded", samples: [pileOfThree(unfolded: false)]),
                    GallerySection.Row(label: "Unfolded", samples: [pileOfThree(unfolded: true)]),
                ])
        }

        private static func pileOfThree(unfolded: Bool) -> ToastPile {
            let pile = ToastPile(foldsOnClickOutside: !unfolded)
            pile.add(toast(ToastContent(variant: .positive, title: "Worktree created", message: nil)))
            pile.add(
                toast(
                    ToastContent(
                        variant: .info, title: "Config reloaded",
                        message: "2 changes applied. Open panes keep their font size.")))
            pile.add(toast(ToastContent(variant: .warning, title: "Couldn't connect to devbox", message: nil)))
            if unfolded { pile.unfold() }
            return pile
        }

        private static func toast(
            _ content: ToastContent, actions: [ToastAction] = [], showsClose: Bool = false
        ) -> ToastView {
            ToastView(content: content, actions: actions, showsClose: showsClose)
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
