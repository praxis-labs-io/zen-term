import AppKit

// Collects a form's problems in field order, so submit can focus the first one.
struct FormValidation {
    private var revealFirst: (() -> Void)?

    var isValid: Bool { revealFirst == nil }

    mutating func flag(_ field: LabeledField?, _ message: String?, at stop: NSView) {
        field?.setMessage(message)
        flag(message != nil) { stop.window?.makeFirstResponder(stop) }
    }

    mutating func flag(_ invalid: Bool, reveal: @escaping () -> Void) {
        guard invalid, revealFirst == nil else { return }
        revealFirst = reveal
    }

    func revealFirstInvalid() {
        revealFirst?()
    }
}
