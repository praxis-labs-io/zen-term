// The words on a `ConfirmCard`, kept apart from it so the app and the gallery raise the same copy.
struct ConfirmPrompt {
    enum Body {
        case message(String)
        case checklist([ConfirmCardChecklist.Item])
    }

    // A close is answered with Return; a delete cannot be undone, so Return there answers nothing.
    enum Start {
        case onConfirm
        case unfocused
    }

    let title: String
    let body: Body
    var cancelLabel = "Cancel"
    let confirmLabel: String
    var start = Start.unfocused

    static let unsavedChanges = ConfirmPrompt(
        title: "Unsaved changes", body: .message("Closing now discards your changes."),
        cancelLabel: "Keep editing", confirmLabel: "Discard changes")
}
