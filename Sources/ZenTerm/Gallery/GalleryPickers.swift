#if DEBUG
    import AppKit

    enum GalleryPickers {
        static let width: CGFloat = 220

        static func sections() -> [GallerySection] {
            [dropdowns(), segmentedControls()]
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
            let checkbox = CheckboxDropdown(title: "3 of 5 shown", items: checkboxItems()) { _ in }
            return GallerySection(
                title: "Dropdown and CheckboxDropdown",
                rows: [
                    GallerySection.Row(label: "Dropdown rest", samples: [sized(plain)]),
                    GallerySection.Row(label: "Dropdown swatch", samples: [sized(swatch)]),
                    GallerySection.Row(label: "Checkbox rest", samples: [sized(checkbox)]),
                ])
        }

        private static func segmentedControls() -> GallerySection {
            let options = ["Off", "Auto", "On"]
            let middle = SegmentedControl(options: options) { _ in }
            middle.setSelection(1)
            let disabled = SegmentedControl(options: options) { _ in }
            disabled.isEnabled = false
            return GallerySection(
                title: "SegmentedControl",
                rows: [
                    GallerySection.Row(label: "First selected", samples: [SegmentedControl(options: options) { _ in }]),
                    GallerySection.Row(label: "Middle selected", samples: [middle]),
                    GallerySection.Row(label: "Disabled", samples: [disabled]),
                ])
        }

        private static func sized<View: NSView>(_ view: View) -> View {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
            return view
        }
    }
#endif
