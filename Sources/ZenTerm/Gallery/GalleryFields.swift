#if DEBUG
    import AppKit

    enum GalleryFields {
        private static let width: CGFloat = 260
        private static let longError =
            "That name is already used by another workspace in this window, so pick a different one."

        static func sections() -> [GallerySection] {
            [boxes(), labeledFields(), errors(), keybindChips(), iconPickers(), workspaceDrawing()]
        }

        private static func boxes() -> GallerySection {
            let field = FieldBox(placeholder: "Workspace name")
            let filledField = FieldBox(placeholder: "Workspace name")
            filledField.setText("api-server")
            let focusedField = FieldBox(placeholder: "Workspace name")
            focusedField.forceFocusForGallery()
            let focusedArea = TextAreaBox(placeholder: "Describe what happened", minHeight: 72)
            focusedArea.forceFocusForGallery()
            let area = TextAreaBox(placeholder: "Describe what happened", minHeight: 72)
            let filledArea = TextAreaBox(placeholder: "Describe what happened", minHeight: 72)
            filledArea.setText("The sidebar stopped updating after I closed the last pane in a tab.")
            let selectedArea = TextAreaBox(placeholder: "Describe what happened", minHeight: 72)
            selectedArea.setText("The sidebar stopped updating after I closed the last pane in a tab.")
            selectedArea.textView.setSelectedRange(NSRange(location: 4, length: 7))
            return GallerySection(
                title: "FieldBox and TextAreaBox",
                rows: [
                    GallerySection.Row(label: "Field placeholder", samples: [sized(field)]),
                    GallerySection.Row(label: "Field filled", samples: [sized(filledField)]),
                    GallerySection.Row(label: "Field focused", samples: [sized(focusedField)]),
                    GallerySection.Row(label: "Area placeholder", samples: [sized(area)]),
                    GallerySection.Row(label: "Area filled", samples: [sized(filledArea)]),
                    GallerySection.Row(label: "Area focused", samples: [sized(focusedArea)]),
                    GallerySection.Row(label: "Area selected", samples: [sized(selectedArea)]),
                ])
        }

        private static func labeledFields() -> GallerySection {
            let withMessage = labeled("Name", required: true)
            withMessage.setMessage("Name is already taken")
            return GallerySection(
                title: "LabeledField and SectionCaption",
                rows: [
                    GallerySection.Row(label: "Caption optional", samples: [sized(labeled("Branch", required: false))]),
                    GallerySection.Row(label: "Caption required", samples: [sized(labeled("Name", required: true))]),
                    GallerySection.Row(label: "Message shown", samples: [sized(withMessage)]),
                ])
        }

        private static func labeled(_ caption: String, required: Bool) -> LabeledField {
            LabeledField(caption: SectionCaption(caption, required: required), control: FieldBox(placeholder: caption))
        }

        private static func errors() -> GallerySection {
            let oneLine = FormErrorLabel(maximumLines: 1)
            oneLine.show(longError)
            let wrapping = FormErrorLabel()
            wrapping.show(longError)
            return GallerySection(
                title: "FormErrorLabel",
                rows: [
                    GallerySection.Row(label: "One line", samples: [sized(oneLine)]),
                    GallerySection.Row(label: "Wrapping", samples: [sized(wrapping)]),
                ])
        }

        private static func keybindChips() -> GallerySection {
            let chip = { () -> KeybindChip in
                let chip = KeybindChip()
                chip.render(shortcut: "⌘⇧P")
                return chip
            }
            let focused = chip()
            focused.setKeyboardFocus(true)
            let capturing = chip()
            capturing.setCapturing(true)
            return GallerySection(
                title: "KeybindChip",
                rows: [
                    GallerySection.Row(label: "Rest", samples: [chip()]),
                    GallerySection.Row(label: "Focused, capturing", samples: [focused, capturing]),
                ])
        }

        private static func iconPickers() -> GallerySection {
            let focused = IconPickerField(selected: "terminal")
            focused.forceFocusForGallery()
            return GallerySection(
                title: "IconPickerField",
                rows: [
                    GallerySection.Row(label: "Rest", samples: [IconPickerField(selected: "terminal")]),
                    GallerySection.Row(label: "Focused", samples: [focused]),
                ])
        }

        private static func workspaceDrawing() -> GallerySection {
            let field = { () -> RegionCommandField in
                let field = RegionCommandField(region: .main)
                field.translatesAutoresizingMaskIntoConstraints = false
                field.heightAnchor.constraint(equalToConstant: WorkspaceTabDrawing.bottomHeight).isActive = true
                return sized(field)
            }
            let rail = { () -> DrawerRail in
                let rail = DrawerRail(region: .bottom)
                rail.translatesAutoresizingMaskIntoConstraints = false
                rail.heightAnchor.constraint(equalToConstant: ChromeMetrics.Height.control).isActive = true
                return sized(rail)
            }
            let focusedField = field()
            focusedField.forceFocusForGallery()
            let focusedRail = rail()
            focusedRail.setKeyboardFocus(true)
            return GallerySection(
                title: "RegionCommandField and DrawerRail",
                rows: [
                    GallerySection.Row(label: "Field rest", samples: [field()]),
                    GallerySection.Row(label: "Field focused", samples: [focusedField]),
                    GallerySection.Row(label: "Rail rest", samples: [rail()]),
                    GallerySection.Row(label: "Rail focused", samples: [focusedRail]),
                ])
        }

        private static func sized<View: NSView>(_ view: View) -> View {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
            return view
        }
    }
#endif
