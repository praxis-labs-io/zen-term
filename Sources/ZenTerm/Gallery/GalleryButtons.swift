#if DEBUG
    import AppKit

    enum GalleryButtons {
        static let variants: [AppButton.Variant] = [.primary, .secondary, .muted, .destructive, .segment, .link]

        static func sections() -> [GallerySection] {
            [appButtons(), iconButtons(), keycaps()]
        }

        static func title(for variant: AppButton.Variant) -> String {
            switch variant {
            case .primary: return "Primary"
            case .secondary: return "Secondary"
            case .muted: return "Muted"
            case .destructive: return "Destructive"
            case .segment: return "Segment"
            case .link: return "Link"
            }
        }

        private static func appButtons() -> GallerySection {
            var rows: [GallerySection.Row] = []
            for variant in variants {
                for (size, sizeName) in [(AppButton.Size.standard, "standard"), (.large, "large")] {
                    rows.append(
                        GallerySection.Row(
                            label: "\(title(for: variant)) · \(sizeName)", samples: states(of: variant, size: size)))
                }
            }
            rows.append(GallerySection.Row(label: "Symbol only", samples: symbolButtons()))
            rows.append(GallerySection.Row(label: "With shortcut", samples: shortcutButtons()))
            return GallerySection(title: "AppButton", rows: rows)
        }

        private static func states(of variant: AppButton.Variant, size: AppButton.Size) -> [NSView] {
            let rest = AppButton(title: "Rest", variant: variant, size: size)
            let hover = hovered(AppButton(title: "Hover", variant: variant, size: size))
            let disabled = AppButton(title: "Disabled", variant: variant, size: size)
            disabled.isEnabled = false
            guard variant == .segment else { return [rest, hover, disabled] }
            let selected = AppButton(title: "Selected", variant: variant, size: size)
            selected.isOn = true
            return [rest, hover, disabled, selected]
        }

        private static func symbolButtons() -> [NSView] {
            let rest = variants.map { AppButton(variant: $0, symbol: "plus") }
            let hover = hovered(AppButton(variant: .muted, symbol: "plus"))
            return rest + [hover]
        }

        private static func shortcutButtons() -> [NSView] {
            let disabled = AppButton(title: "Disabled", variant: .primary, shortcut: "⏎")
            disabled.isEnabled = false
            return [
                AppButton(title: "Connect", variant: .primary, shortcut: "⏎"),
                AppButton(title: "Connect", variant: .primary, size: .large, shortcut: "⏎"),
                AppButton(title: "Cancel", variant: .secondary, shortcut: "esc"),
                AppButton(title: "Open", variant: .muted, shortcut: "⌘O"),
                disabled,
            ]
        }

        private static func hovered(_ button: AppButton) -> AppButton {
            let entered = NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
            if let entered { button.mouseEntered(with: entered) }
            return button
        }

        private static func iconButtons() -> GallerySection {
            let active = iconButton()
            active.isActive = true
            let activity = SurfaceAttention.allCases.map { state -> NSView in
                let button = iconButton()
                button.showsActivity = true
                button.activityState = state
                return button
            }
            return GallerySection(
                title: "IconButton",
                rows: [
                    GallerySection.Row(label: "Rest", samples: [iconButton()]),
                    GallerySection.Row(label: "Active", samples: [active]),
                    GallerySection.Row(label: "Rests filled", samples: [iconButton(restsFilled: true)]),
                    GallerySection.Row(label: "Activity: idle, working, done, waiting", samples: activity),
                ])
        }

        private static func iconButton(restsFilled: Bool = false) -> IconButton {
            IconButton(
                symbol: "sidebar.left", accessibilityLabel: "Toggle sidebar", shortcut: { "⌘B" },
                restsFilled: restsFilled, onClick: {})
        }

        private static func keycaps() -> GallerySection {
            let shortcut = "⌘⇧P"
            return GallerySection(
                title: "KeycapView",
                rows: [
                    GallerySection.Row(label: "Chip", samples: [KeycapView(shortcut: shortcut, style: .chip)]),
                    GallerySection.Row(label: "Plain", samples: [KeycapView(shortcut: shortcut, style: .plain)]),
                    GallerySection.Row(
                        label: "Glyph accent",
                        samples: [KeycapView(shortcut: shortcut, style: .glyph { $0.accent.nsColor })]),
                    GallerySection.Row(
                        label: "Glyph faint",
                        samples: [KeycapView(shortcut: shortcut, style: .glyph { $0.ink(.faint) })]),
                ])
        }
    }
#endif
