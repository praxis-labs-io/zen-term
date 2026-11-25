#if DEBUG
    import AppKit

    enum GalleryButtons {
        static let variants: [AppButton.Variant] = [.primary, .secondary, .muted, .destructive, .link, .quietLink]

        static func sections() -> [GallerySection] {
            [appButtons(), iconButtons(), keycaps(), stateDots()]
        }

        static func title(for variant: AppButton.Variant) -> String {
            switch variant {
            case .primary: return "Primary"
            case .secondary: return "Secondary"
            case .muted: return "Muted"
            case .destructive: return "Destructive"
            case .link: return "Link"
            case .quietLink: return "Quiet link"
            }
        }

        private static func appButtons() -> GallerySection {
            var rows: [GallerySection.Row] = []
            for variant in variants {
                rows.append(GallerySection.Row(label: title(for: variant), samples: states(of: variant)))
            }
            rows.append(GallerySection.Row(label: "Symbol only", samples: symbolButtons()))
            return GallerySection(title: "AppButton", rows: rows)
        }

        private static func states(of variant: AppButton.Variant) -> [NSView] {
            let rest = AppButton(title: "Rest", variant: variant)
            let hover = hovered(AppButton(title: "Hover", variant: variant))
            let focused = AppButton(title: "Focused", variant: variant)
            focused.forceFocusForGallery()
            let disabled = AppButton(title: "Disabled", variant: variant)
            disabled.isEnabled = false
            return [rest, hover, focused, disabled]
        }

        private static func symbolButtons() -> [NSView] {
            let rest = variants.map { AppButton(variant: $0, symbol: "plus") }
            let hover = hovered(AppButton(variant: .muted, symbol: "plus"))
            return rest + [hover]
        }

        private static func hovered(_ button: AppButton) -> AppButton {
            let entered = NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
            if let entered { button.mouseEntered(with: entered) }
            return button
        }

        private static func iconButtons() -> GallerySection {
            let hovered = iconButton()
            hovered.forceHoverForGallery()
            let active = iconButton()
            active.isActive = true
            let live = iconButton()
            live.showsActivity = true
            return GallerySection(
                title: "IconButton",
                rows: [
                    GallerySection.Row(label: "Rest", samples: [iconButton()]),
                    GallerySection.Row(label: "Hover", samples: [hovered]),
                    GallerySection.Row(label: "Active", samples: [active]),
                    GallerySection.Row(label: "Rests filled", samples: [iconButton(restsFilled: true)]),
                    GallerySection.Row(label: "Live in the background", samples: [live]),
                ])
        }

        private static func stateDots() -> GallerySection {
            GallerySection(
                title: "StateDot",
                rows: [
                    GallerySection.Row(
                        label: "Blocked, done, idle, live, online", samples: StateDot.State.allCases.map(StateDot.init))
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
                ])
        }
    }
#endif
