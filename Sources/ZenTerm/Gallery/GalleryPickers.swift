#if DEBUG
    import AppKit

    enum GalleryPickers {
        static let width: CGFloat = 220

        static func sections() -> [GallerySection] {
            [listRows(), focusRows(), dropdowns(), segmentedControls()]
        }

        static func liveDropdown() -> Dropdown {
            let chrome = Theme.current.chrome
            let selected = 2
            let roles: [(String, NSColor, String?)] = [
                ("Accent", chrome.accent.nsColor, "Swatch"),
                ("Info", chrome.info.nsColor, nil),
                ("Positive", chrome.positive.nsColor, "Selected"),
                ("Warning", chrome.warning.nsColor, nil),
            ]
            var items = roles.enumerated().map { index, role in
                DropdownItem(
                    title: role.0, group: "With swatch", note: role.2, isSelected: index == selected, swatch: role.1)
            }
            items += [
                DropdownItem(title: "With note", group: "Plain", note: "Note", isSelected: false),
                DropdownItem(title: "No note", group: "Plain", note: nil, isSelected: false),
            ]
            return sized(Dropdown(items: items, selectedIndex: selected) { _ in })
        }

        static func liveCheckboxDropdown() -> CheckboxDropdown {
            sized(CheckboxDropdown(title: "3 of 5 shown", items: checkboxItems()) { _ in })
        }

        private static func checkboxItems() -> [CheckboxDropdownItem] {
            [
                CheckboxDropdownItem(title: "Checked", isChecked: true),
                CheckboxDropdownItem(title: "Unchecked", isChecked: false),
                CheckboxDropdownItem(title: "With note", isChecked: true, note: "Note"),
                CheckboxDropdownItem(title: "With icon", isChecked: false, symbol: "terminal"),
                CheckboxDropdownItem(title: "Icon and note", isChecked: true, note: "Note", symbol: "folder"),
            ]
        }

        private static func listRows() -> GallerySection {
            let row = { (content: ListRow.Content) in sized(ListRow(content) {}) }
            let highlighted = row(ListRow.Content(title: "Keyboard cursor"))
            highlighted.isHighlighted = true
            let focused = row(ListRow.Content(title: "Focused"))
            focused.setKeyboardFocus(true)
            let current = row(ListRow.Content(title: "Workspaces"))
            current.isCurrent = true
            return GallerySection(
                title: "ListRow",
                rows: [
                    GallerySection.Row(label: "Rest", samples: [row(ListRow.Content(title: "Title"))]),
                    GallerySection.Row(label: "Keyboard cursor", samples: [highlighted]),
                    GallerySection.Row(label: "Focused", samples: [focused]),
                    GallerySection.Row(
                        label: "Current", samples: [row(ListRow.Content(title: "Selected", trailing: .check)), current]),
                    GallerySection.Row(
                        label: "Subtitle",
                        samples: [row(ListRow.Content(title: "zen-term", subtitle: "~/Dev/zen-term"))]),
                    GallerySection.Row(
                        label: "Icon on the title line",
                        samples: [
                            row(
                                ListRow.Content(
                                    title: "Review x.swift", subtitle: "zen-term", leading: .symbol("terminal"),
                                    leadingOnTitleLine: true))
                        ]),
                    GallerySection.Row(
                        label: "Nested",
                        samples: [
                            row(
                                ListRow.Content(
                                    title: "feature/zen-677", leading: .symbol("arrow.branch"), nesting: .indented)
                            )
                        ]),
                    GallerySection.Row(
                        label: "Icon and note",
                        samples: [row(ListRow.Content(title: "main", note: "Note", leading: .symbol("arrow.branch")))]),
                    GallerySection.Row(
                        label: "Swatch",
                        samples: [
                            row(ListRow.Content(title: "Accent", leading: .swatch(Theme.current.chrome.accent.nsColor)))
                        ]),
                    GallerySection.Row(
                        label: "Keycap", samples: [row(ListRow.Content(title: "Close", trailing: .keycap("⌘⌃W")))]),
                    GallerySection.Row(
                        label: "Receding",
                        samples: [row(ListRow.Content(title: "Unchecked", leading: .symbol("terminal"), ink: .muted))]
                    ),
                ])
        }

        private static func focusRows() -> GallerySection {
            let nav = { sized(NavRow(title: "General") {}) }
            let settings = { sized(SettingsFocusRow(ListRow.Content(title: "api-server", subtitle: "~/Dev/api"))) }
            let jump = { sized(SidebarJumpRow(ListRow.Content(title: "zen-term"), tooltip: "Jump") {}) }
            let focused = { (row: ListRow) -> ListRow in
                row.setKeyboardFocus(true)
                return row
            }
            return GallerySection(
                title: "NavRow, SettingsFocusRow and SidebarJumpRow",
                rows: [
                    GallerySection.Row(label: "NavRow", samples: [nav(), focused(nav())]),
                    GallerySection.Row(label: "SettingsFocusRow", samples: [settings(), focused(settings())]),
                    GallerySection.Row(label: "SidebarJumpRow", samples: [jump(), focused(jump())]),
                ])
        }

        private static func dropdowns() -> GallerySection {
            let plain = Dropdown(
                items: [
                    DropdownItem(title: "Rosé Pine", group: nil, note: nil, isSelected: true),
                    DropdownItem(title: "Nord", group: nil, note: nil, isSelected: false),
                ],
                selectedIndex: 0
            ) { _ in }
            let swatch = Dropdown(
                items: [
                    DropdownItem(
                        title: "Accent", group: nil, note: nil, isSelected: true,
                        swatch: Theme.current.chrome.accent.nsColor)
                ],
                selectedIndex: 0
            ) { _ in }
            let focused = Dropdown(
                items: [DropdownItem(title: "Rosé Pine", group: nil, note: nil, isSelected: true)], selectedIndex: 0
            ) { _ in }
            focused.forceFocusForGallery()
            let checkbox = CheckboxDropdown(title: "3 of 5 shown", items: checkboxItems()) { _ in }
            let focusedCheckbox = CheckboxDropdown(title: "3 of 5 shown", items: checkboxItems()) { _ in }
            focusedCheckbox.forceFocusForGallery()
            return GallerySection(
                title: "Dropdown and CheckboxDropdown",
                rows: [
                    GallerySection.Row(label: "Dropdown rest", samples: [sized(plain)]),
                    GallerySection.Row(label: "Dropdown swatch", samples: [sized(swatch)]),
                    GallerySection.Row(label: "Dropdown focused", samples: [sized(focused)]),
                    GallerySection.Row(label: "Checkbox rest", samples: [sized(checkbox)]),
                    GallerySection.Row(label: "Checkbox focused", samples: [sized(focusedCheckbox)]),
                ])
        }

        private static func segmentedControls() -> GallerySection {
            let options = ["Off", "Auto", "On"]
            let hover = SegmentedControl(options: options) { _ in }
            hover.forceHoverForGallery(segment: 2)
            let selected = SegmentedControl(options: options) { _ in }
            selected.setSelection(1)
            let focused = SegmentedControl(options: options) { _ in }
            focused.forceFocusForGallery()
            let disabled = SegmentedControl(options: options) { _ in }
            disabled.isEnabled = false
            return GallerySection(
                title: "SegmentedControl",
                rows: [
                    GallerySection.Row(label: "Rest", samples: [SegmentedControl(options: options) { _ in }]),
                    GallerySection.Row(label: "Hover", samples: [hover]),
                    GallerySection.Row(label: "Selected", samples: [selected]),
                    GallerySection.Row(label: "Focused", samples: [focused]),
                    GallerySection.Row(label: "Disabled", samples: [disabled]),
                ])
        }

        private static func sized<View: NSView>(_ view: View) -> View {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
            return view
        }
    }
#endif
