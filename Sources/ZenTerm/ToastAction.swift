import AppKit

/// One button on an actionable (confirm) toast.
struct ToastAction {
    enum Kind { case primary, cancel, destructive }
    let title: String
    let kind: Kind
    let run: () -> Void
}
