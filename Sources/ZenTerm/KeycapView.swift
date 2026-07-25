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

    /// The chord this keycap draws. Baked at construction (every token colors itself then), so a
    /// host whose glyph can change re-reads this and rebuilds rather than mutating in place.
    let shortcut: String
    private let showsBackground: Bool
    /// The glyph-token row, retained so `reapplyTheme()` can rebuild it — every token bakes its
    /// ink/tint color in at construction (there's nothing to mutate in place).
    private let tokenStack: NSStackView

    /// `showsBackground: false` renders just the glyph tokens with no rounded fill — for a host that
    /// supplies its own background (the keybind chip's full-width focus target).
    init(shortcut: String, showsBackground: Bool = true) {
        self.shortcut = shortcut
        self.showsBackground = showsBackground
        // A horizontal run of icon/text tokens; the spacing keeps the glyphs from crowding.
        let stack = NSStackView(views: Self.tokens(for: shortcut))
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.alignment = .centerY
        tokenStack = stack
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        if showsBackground { layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor }
        translatesAutoresizingMaskIntoConstraints = false

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

    /// Re-apply the live chrome colors after a config change — no relaunch. Every token (modifier
    /// icon tint, key-label ink) bakes its color in at construction, so rebuild them fresh against
    /// `Theme.current` rather than mutate in place — the same pattern `KeybindRow.reapplyTheme()`
    /// already uses for its nested `KeycapView` (re-render, don't patch).
    func reapplyTheme() {
        if showsBackground { layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor }
        tokenStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        Self.tokens(for: shortcut).forEach { tokenStack.addArrangedSubview($0) }
    }

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
        view.image = glyphImage(symbol)
        view.contentTintColor = ink
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    /// The glyph images, resolved once per symbol and shared by every keycap on screen. The tint
    /// lives on the image VIEW (`contentTintColor`), never on the image, so sharing one instance is
    /// safe and `reapplyTheme()` still recolors. Every keycap draws at the same fixed size, so
    /// there's one configuration to cache; the palette rebuilds rows per keystroke, which made this
    /// a symbol lookup per token per row (ZEN-15). Main-thread only, like the views it feeds.
    private static var glyphImages: [String: NSImage?] = [:]

    private static func glyphImage(_ symbol: String) -> NSImage? {
        if let cached = glyphImages[symbol] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
            .withSymbolConfiguration(config)
        glyphImages[symbol] = image
        return image
    }

    private static func keyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = ink
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
