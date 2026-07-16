/// One button on an actionable (confirm) toast.
struct ToastAction {
    enum Kind { case cancel, destructive }
    let title: String
    let kind: Kind
    /// The chord this action's key is bound to, shown as a keycap beside the title — resolved
    /// lazily, never baked, so the glyph tracks a rebind or a tab move while the toast is up.
    /// Displaying it arms nothing: the binding it names is the app's own (the waiting toast is
    /// non-modal, and ZEN-106 guarantees a toast never steals keys from the terminal).
    let shortcut: (() -> String)?
    let run: () -> Void

    init(title: String, kind: Kind, shortcut: (() -> String)? = nil, run: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.shortcut = shortcut
        self.run = run
    }
}
