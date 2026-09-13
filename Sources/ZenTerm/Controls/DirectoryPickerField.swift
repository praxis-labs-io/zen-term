import AppKit

final class DirectoryPickerField: NSView, ThemeReapplying {
    let field: FieldBox
    let chooseButton = AppButton(title: "Choose", variant: .muted)
    var onPicked: ((URL) -> Void)?

    var presentPanel: (_ host: NSWindow?, _ start: URL, _ completion: @escaping (URL?) -> Void) -> Void =
        DirectoryPickerField.nativePanel

    init(placeholder: String) {
        field = FieldBox(placeholder: placeholder)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        chooseButton.isKeyboardFocusable = true
        chooseButton.onTap = { [weak self] in self?.choose() }

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

    private func choose() {
        presentPanel(field.window, startDirectory) { [weak self] url in
            guard let self, let url else { return }
            self.field.setText(PathDisplay.abbreviatingHome(url.path))
            self.onPicked?(url)
        }
    }

    private var startDirectory: URL {
        let trimmed = field.text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let url = URL(fileURLWithPath: PathDisplay.expandingHome(trimmed))
            if PathDisplay.isDirectory(url) { return url }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

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
