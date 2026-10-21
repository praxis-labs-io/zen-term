#if DEBUG
    import AppKit
    import TabKit

    enum GalleryTabs {
        private static let longTitle = "a-workspace-name-long-enough-to-truncate-in-its-chip"

        static func sections() -> [GallerySection] {
            [tabBar(), workspaceChips()]
        }

        static func renameChip() -> WorkspaceTabChip {
            chip(title: "api-server", selected: true)
        }

        static func host(_ chip: WorkspaceTabChip) -> NSView {
            let host = NSView()
            host.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(chip)
            let width = host.widthAnchor.constraint(equalToConstant: chip.fittingWidth)
            NSLayoutConstraint.activate([width, host.heightAnchor.constraint(equalToConstant: WorkspaceTabChip.height)])
            chip.frame = NSRect(x: 0, y: 0, width: chip.fittingWidth, height: WorkspaceTabChip.height)
            chip.onWidthChanged = { [weak chip] in
                guard let chip else { return }
                width.constant = chip.fittingWidth
                chip.setFrameSize(NSSize(width: chip.fittingWidth, height: WorkspaceTabChip.height))
            }
            return host
        }

        private static func tabBar() -> GallerySection {
            let bar = TabBarView(onSelect: { _ in }, onClose: { _ in }, onRename: { _ in })
            bar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: 640),
                bar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            ])
            bar.render([
                TabBarItem(id: TabID(1), index: 1, title: "active", isActive: true, attentionState: .idle),
                TabBarItem(id: TabID(2), index: 2, title: "hover", isActive: false, attentionState: .completed),
                TabBarItem(id: TabID(3), index: 3, title: "completed", isActive: false, attentionState: .completed),
                TabBarItem(id: TabID(4), index: 4, title: "waiting", isActive: false, attentionState: .waiting),
                TabBarItem(id: TabID(5), index: 5, title: longTitle, isActive: false, attentionState: .idle),
            ])
            bar.forceHoverForGallery(tab: TabID(2))
            return GallerySection(
                title: "TabBarView",
                rows: [GallerySection.Row(label: "Active, hover over a dot, attention, long", samples: [bar])])
        }

        private static func workspaceChips() -> GallerySection {
            let hovered = chip(title: "hover", removable: true)
            hovered.setHover(true)
            let hoveredOverDot = chip(title: "hover", opensFocused: true, removable: true)
            hoveredOverDot.setHover(true)
            let focused = chip(title: "focused")
            focused.forceFocusForGallery()
            return GallerySection(
                title: "WorkspaceTabChip",
                rows: [
                    GallerySection.Row(label: "Rest", samples: [host(chip(title: "rest"))]),
                    GallerySection.Row(label: "Hover, removable", samples: [host(hovered)]),
                    GallerySection.Row(label: "Hover over the dot", samples: [host(hoveredOverDot)]),
                    GallerySection.Row(label: "Focused", samples: [host(focused)]),
                    GallerySection.Row(
                        label: "Opens focused", samples: [host(chip(title: "focused", opensFocused: true))]),
                    GallerySection.Row(label: "Long title", samples: [host(chip(title: longTitle))]),
                    GallerySection.Row(label: "Strip, selected tab on the pill", samples: [strip()]),
                ])
        }

        private static func strip() -> WorkspaceTabStrip {
            var form = WorkspaceForm(
                editing: Workspace(
                    title: "api", path: URL(fileURLWithPath: "/tmp"),
                    tabs: [Workspace.Tab(main: "nvim"), Workspace.Tab(name: "gate"), Workspace.Tab()],
                    focus: .start, env: [:]))
            form.select(1)
            let strip = WorkspaceTabStrip()
            strip.render(form)
            strip.widthAnchor.constraint(equalToConstant: 420).isActive = true
            return strip
        }

        private static func chip(
            title: String, selected: Bool = false, opensFocused: Bool = false, removable: Bool = false
        ) -> WorkspaceTabChip {
            let chip = WorkspaceTabChip()
            chip.update(
                title: title, defaultName: "Workspace", selected: selected, opensFocused: opensFocused,
                removable: removable)
            return chip
        }
    }
#endif
