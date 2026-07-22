import AppKit

/// A directory input: an editable text field plus a trailing "Choose" button (far right) that opens
/// a native directory panel and fills the field with the chosen path, home-abbreviated. The button
/// is a real focus stop — arrow / Tab reachable like the form's other controls — rather than a
/// click-on-the-input affordance, so it works whether the field is empty or already holds a path.
///
/// `field` and `chooseButton` are exposed so the host form wires them into its own arrow / Tab
/// navigation, exactly like an env row's KEY field + remove button: the field is the vertical stop,
/// Right reaches the button, Left returns. A shared form-control primitive.
final class DirectoryPickerField: NSView, ThemeReapplying {
    let field: FieldBox
    let chooseButton = AppButton(title: "Choose", variant: .muted)
    /// Runs after a pick fills the field — the host refreshes validity and can seed a sibling field.
    var onPicked: ((URL) -> Void)?

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

    /// Open the directory panel; on choose, fill the field (home-abbreviated) and run `onPicked`.
    /// Presents as a sheet on the field's window. Fired from the button's action (release-based),
    /// so the sheet attaches cleanly.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        // Start where the user is: the path already typed if it's a real directory, else home —
        // never wherever the panel happened to land last (that opened at /Library).
        panel.directoryURL = startDirectory
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.field.setText(PathDisplay.abbreviatingHome(url.path))
            self.onPicked?(url)
        }
        if let window = field.window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            panel.begin(completionHandler: handle)
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
}
