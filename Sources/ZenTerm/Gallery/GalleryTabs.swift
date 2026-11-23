#if DEBUG
    import AppKit
    import TabKit

    enum GalleryTabs {
        private static let longTitle = "a-workspace-name-long-enough-to-truncate-in-its-chip"

        static func sections() -> [GallerySection] {
            [tabBar(), processChips(), workspaceChips()]
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
                TabBarItem(
                    id: TabID(1), index: 1, title: "active", isActive: true, indicator: nil, process: .shell),
                TabBarItem(
                    id: TabID(2), index: 2, title: "hover", isActive: false, indicator: .dot(.blocked),
                    process: ProcessIcon.forProgram("nvim")),
                TabBarItem(
                    id: TabID(3), index: 3, title: "blocked", isActive: false, indicator: .dot(.blocked),
                    process: ProcessIcon.forAgent("claude")),
                TabBarItem(
                    id: TabID(4), index: 4, title: "done", isActive: false, indicator: .dot(.done),
                    process: ProcessIcon.forAgent("codex")),
                TabBarItem(
                    id: TabID(5), index: 5, title: "working", isActive: false, indicator: .spinner,
                    process: ProcessIcon.forAgent("gemini")),
                TabBarItem(id: TabID(6), index: 6, title: longTitle, isActive: false, indicator: nil),
            ])
            bar.forceHoverForGallery(tab: TabID(2))
            return GallerySection(
                title: "TabBarView",
                rows: [
                    GallerySection.Row(label: "Active, hover over a dot, blocked, done, working, long", samples: [bar])
                ])
        }

        private static func processChips() -> GallerySection {
            let icons: [ProcessIcon] = [
                ProcessIcon.forAgent("claude"), ProcessIcon.forAgent("codex"), ProcessIcon.forAgent("gemini"),
                ProcessIcon.forAgent("pi"), ProcessIcon.forProgram("docker"), .shell, .unknownAgent, .worktree,
            ]
            return GallerySection(
                title: "IconBadge: process chips",
                rows: [IconBadge.Size.small, .regular].map { size in
                    GallerySection.Row(
                        label: "Brand, artwork, generic, worktree",
                        samples: icons.map { IconBadge(process: $0, size: size) })
                })
        }

        private static func workspaceChips() -> GallerySection {
            let hovered = chip(title: "hover", removable: true)
            hovered.setHovered(true)
            let hoveredOverDot = chip(title: "hover", opensFocused: true, removable: true)
            hoveredOverDot.setHovered(true)
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
