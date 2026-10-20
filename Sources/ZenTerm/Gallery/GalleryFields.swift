#if DEBUG
    import AppKit

    enum GalleryFields {
        private static let width: CGFloat = 260
        private static let longError =
            "That name is already used by another workspace in this window, so pick a different one."

        static func sections() -> [GallerySection] {
            [boxes(), labeledFields(), errors()]
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
            return GallerySection(
                title: "FieldBox and TextAreaBox",
                rows: [
                    GallerySection.Row(label: "Field placeholder", samples: [sized(field)]),
                    GallerySection.Row(label: "Field filled", samples: [sized(filledField)]),
                    GallerySection.Row(label: "Field focused", samples: [sized(focusedField)]),
                    GallerySection.Row(label: "Area placeholder", samples: [sized(area)]),
                    GallerySection.Row(label: "Area filled", samples: [sized(filledArea)]),
                    GallerySection.Row(label: "Area focused", samples: [sized(focusedArea)]),
                ])
        }

        private static func labeledFields() -> GallerySection {
            let withMessage = labeled("Name", required: true)
            withMessage.setMessage("Name is already taken")
            return GallerySection(
                title: "LabeledField and FieldCaption",
                rows: [
                    GallerySection.Row(label: "Caption optional", samples: [sized(labeled("Branch", required: false))]),
                    GallerySection.Row(label: "Caption required", samples: [sized(labeled("Name", required: true))]),
                    GallerySection.Row(label: "Message shown", samples: [sized(withMessage)]),
                ])
        }

        private static func labeled(_ caption: String, required: Bool) -> LabeledField {
            LabeledField(caption: FieldCaption(caption, required: required), control: FieldBox(placeholder: caption))
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

        private static func sized(_ view: NSView) -> NSView {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
            return view
        }
    }
#endif
