import AppKit

/// A small rounded box holding a keyboard shortcut, e.g. ⌘⇧P. Modifier glyphs render as
/// crisp SF Symbols (command/shift/option/control); the key itself renders as muted
/// monospaced text. Shares the chrome's rounded-6 box idiom with `IconButton` and the
/// tab-bar `Chip`: faint fill, muted ink. Shown at a command-palette row's trailing edge.
final class KeycapView: NSView {
    /// Glyphs that map to an SF Symbol — modifiers plus the navigation keys used in the
    /// footer hints. Everything else (letters, digits, and punctuation keys like `- | [ ]
    /// \`) has no clean symbol and stays as text.
    private static let glyphSymbols: [Character: String] = [
        "⌘": "command", "⇧": "shift", "⌥": "option", "⌃": "control",
        "⏎": "return", "↵": "return", "⎋": "escape",
        "↑": "arrow.up", "↓": "arrow.down", "←": "arrow.left", "→": "arrow.right",
    ]
    private static var ink: NSColor { Theme.current.chrome.ink(alpha: 0.55) }

    /// `showsBackground: false` renders just the glyph tokens with no rounded fill — for a host that
    /// supplies its own background (the keybind chip's full-width focus target).
    init(shortcut: String, showsBackground: Bool = true) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        if showsBackground { layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor }
        translatesAutoresizingMaskIntoConstraints = false

        // A horizontal run of icon/text tokens; the spacing keeps the glyphs from crowding.
        let stack = NSStackView(views: Self.tokens(for: shortcut))
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Split the shortcut into views: an SF Symbol per modifier glyph and a monospaced
    /// text run for each maximal stretch of key characters.
    private static func tokens(for shortcut: String) -> [NSView] {
        var views: [NSView] = []
        var run = ""
        func flushRun() {
            if !run.isEmpty {
                views.append(keyLabel(run))
                run = ""
            }
        }
        for ch in shortcut {
            if let symbol = glyphSymbols[ch] {
                flushRun()
                views.append(modifierIcon(symbol))
            } else {
                run.append(ch)
            }
        }
        flushRun()
        return views
    }

    private static func modifierIcon(_ symbol: String) -> NSView {
        let view = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
            .withSymbolConfiguration(config)
        view.contentTintColor = ink
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private static func keyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = ink
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
