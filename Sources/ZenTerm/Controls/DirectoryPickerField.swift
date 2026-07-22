import AppKit

/// A directory input: an editable text field plus a trailing "Choose" button (far right) that opens
/// a native directory panel and fills the field with the chosen path, home-abbreviated. The button
/// is a real focus stop — arrow / Tab reachable like the form's other controls — rather than a
/// click-on-the-input affordance, so it works whether the field is empty or already holds a path.
///
/// The field is exposed so the host wires it as a vertical stop (`wireField`); the button ↔ field
/// focus partnership (Right reaches the button, Left / Shift-Tab return) is owned here, and the
/// host hands back only the two moves that leave the pair — see `wireNav`.
final class DirectoryPickerField: NSView, ThemeReapplying {
    let field: FieldBox
    let chooseButton = AppButton(title: "Choose", variant: .muted)
    /// Runs after a pick fills the field — the host refreshes validity and can seed a sibling field.
    var onPicked: ((URL) -> Void)?

    /// Seam: present a directory chooser starting at `start`, calling back with the chosen URL (nil
    /// if cancelled). Defaults to a native `NSOpenPanel` sheet; tests replace it so no real panel is
    /// presented (and can assert where it would have opened).
    var presentPanel: (_ host: NSWindow?, _ start: URL, _ completion: @escaping (URL?) -> Void) -> Void =
        DirectoryPickerField.nativePanel

    init(placeholder: String) {
        field = FieldBox(placeholder: placeholder)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        chooseButton.isKeyboardFocusable = true
        chooseButton.onTap = { [weak self] in self?.choose() }

        // The field takes the row's slack; the button keeps its natural width at the far right.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chooseButton.setContentHuggingPriority(.required, for: .horizontal)
        chooseButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [field, chooseButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var text: String { field.text }
    func setText(_ value: String) { field.setText(value) }

    func reapplyTheme() {
        field.reapplyTheme()
        chooseButton.reapplyTheme()
    }

    /// Wire the button into the host form's navigation: the field stays the vertical stop and the
    /// button hangs off it horizontally (Right reaches it, Left / Shift-Tab return) — the same shape
    /// as an env row's remove button. The host supplies only the moves that leave the pair: `onVertical`
    /// for Up/Down, `onTabForward` for a forward Tab off the button. Call after the host's `wireField`,
    /// since it overrides the field's Right/Tab.
    func wireNav(onVertical: @escaping (Int) -> Void, onTabForward: @escaping () -> Void) {
        field.onArrowRight = { [weak self] in self?.focusButton() }
        field.onTab = { [weak self] in self?.focusButton() }
        chooseButton.onArrowLeft = { [weak self] in self?.focusField() }
        chooseButton.onBacktab = { [weak self] in self?.focusField() }
        chooseButton.onArrowUp = { onVertical(-1) }
        chooseButton.onArrowDown = { onVertical(1) }
        chooseButton.onTab = { onTabForward() }
    }

    private func focusButton() { window?.makeFirstResponder(chooseButton) }
    private func focusField() { window?.makeFirstResponder(field.field) }

    /// Open the directory panel; on choose, fill the field (home-abbreviated) and run `onPicked`.
    /// Fired from the button's action (release-based), so the sheet attaches cleanly.
    private func choose() {
        presentPanel(field.window, startDirectory) { [weak self] url in
            guard let self, let url else { return }
            self.field.setText(PathDisplay.abbreviatingHome(url.path))
            self.onPicked?(url)
        }
    }

    /// The directory the panel opens on: the field's current path when it points at a real folder,
    /// otherwise the user's home.
    private var startDirectory: URL {
        let trimmed = field.text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let url = URL(fileURLWithPath: PathDisplay.expandingHome(trimmed))
            if PathDisplay.isDirectory(url) { return url }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The default `presentPanel`: a native directory `NSOpenPanel` presented as a sheet. Starts at
    /// `start` (never wherever the panel last landed, which opened at /Library).
    private static func nativePanel(host: NSWindow?, start: URL, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = start
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.url : nil)
        }
        if let host {
            panel.beginSheetModal(for: host, completionHandler: handle)
        } else {
            panel.begin(completionHandler: handle)
        }
    }
}
