import AppKit

/// One web-pane preset: a display label and the URL it opens.
struct WebPanePreset {
    let label: String
    let url: URL
}

/// The `⌘⇧B` web-pane picker: a modal palette over the tab's tile region listing URL
/// presets. Enter splits a web pane from the focused pane, Shift+Enter replaces the
/// focused pane, Esc / backdrop click dismiss. Built on `PaletteOverlay` (card/list/
/// keyboard scaffolding); this supplies the preset rows + filter.
final class WebPanePickerOverlay: PaletteOverlay {
    /// The v1 presets — hardcoded, configurable later (per the design spec).
    static let defaultPresets: [WebPanePreset] = [
        ("localhost:3000", "http://localhost:3000"),
        ("localhost:3001", "http://localhost:3001"),
        ("localhost:3002", "http://localhost:3002"),
        ("team.localhost:3000", "http://team.localhost:3000"),
        ("admin.localhost:3000", "http://admin.localhost:3000"),
    ].compactMap { label, string in
        URL(string: string).map { WebPanePreset(label: label, url: $0) }
    }

    /// (selected URL, replaceFocused). `replaceFocused` is Shift+Enter.
    private let onChoose: (URL, Bool) -> Void

    private let presets: [WebPanePreset]
    private var filtered: [WebPanePreset]

    init(
        presets: [WebPanePreset], background: NSColor,
        onChoose: @escaping (URL, Bool) -> Void, onDismiss: @escaping () -> Void
    ) {
        self.presets = presets
        self.filtered = presets
        self.onChoose = onChoose
        super.init(
            background: background,
            placeholder: "Open URL…",
            emptyText: "No presets",
            footerHints: [
                PaletteHint(keys: "⏎", label: "split"),
                PaletteHint(keys: "⇧⏎", label: "replace"),
                PaletteHint(keys: "↑↓", label: "move"),
                PaletteHint(keys: "⎋", label: "close"),
            ],
            rowHeight: 32,
            onDismiss: onDismiss)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func numberOfRows() -> Int { filtered.count }

    override func makeRow(at index: Int) -> PaletteRowView {
        RowView(preset: filtered[index]) { [weak self] clickCount in
            self?.selectRow(at: index, clickCount: clickCount)
        }
    }

    override func applyFilter(query: String) {
        let q = query.lowercased()
        if q.isEmpty {
            filtered = presets
        } else {
            filtered = presets.filter { $0.label.lowercased().contains(q) }
        }
    }

    override func activate(index: Int, modifiers: NSEvent.ModifierFlags) {
        guard filtered.indices.contains(index) else { return }
        onChoose(filtered[index].url, modifiers.contains(.shift))
    }

    /// One preset row: the label (left) and a muted globe glyph (right).
    private final class RowView: SelectableRowView {
        init(preset: WebPanePreset, onClick: @escaping (Int) -> Void) {
            super.init(onClick: onClick)

            let label = NSTextField(labelWithString: preset.label)
            label.font = .systemFont(ofSize: 13)
            label.textColor = Theme.current.chrome.foreground.nsColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])

            let globe = NSImageView()
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            globe.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "web page")?
                .withSymbolConfiguration(config)
            globe.contentTintColor = Theme.current.chrome.ink(alpha: 0.35)
            globe.translatesAutoresizingMaskIntoConstraints = false
            addSubview(globe)
            globe.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14).isActive = true
            globe.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }
}
