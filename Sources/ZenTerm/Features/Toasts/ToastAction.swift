struct ToastAction {
    enum Kind { case cancel, destructive, primary }
    let title: String
    let kind: Kind
    /// Resolved lazily so the keycap tracks a rebind while the toast is up.
    let shortcut: (() -> String)?
    let run: () -> Void

    init(title: String, kind: Kind, shortcut: (() -> String)? = nil, run: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.shortcut = shortcut
        self.run = run
    }
}
