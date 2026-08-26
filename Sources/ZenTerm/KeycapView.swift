import AppKit

/// A small rounded box holding a keyboard shortcut, e.g. ⌘⇧P. Modifier glyphs render as
/// crisp SF Symbols (command/shift/option/control); the key itself renders as muted
/// monospaced text. Shares the chrome's rounded-6 box idiom with `IconButton` and the
/// tab-bar `Chip`: faint fill, muted ink. Shown at a command-palette row's trailing edge.
final class KeycapView: NSView {
    /// The one footprint a keycap draws at, for command-palette rows and settings chips.
    private static let height: CGFloat = 20
    private static let horizontalInset: CGFloat = 7
    private static let cornerRadius: CGFloat = 6
    private static let tokenSpacing: CGFloat = 3
    private static let symbolPointSize: CGFloat = 10
    private static let labelFontSize: CGFloat = 11

    /// Glyphs that map to an SF Symbol — modifiers plus the navigation keys used in the
    /// footer hints. Everything else (letters, digits, and punctuation keys like `- | [ ]
    /// \`) has no clean symbol and stays as text.
    private static let glyphSymbols: [Character: String] = [
        "⌘": "command", "⇧": "shift", "⌥": "option", "⌃": "control",
        "⏎": "return", "↵": "return", "⎋": "escape",
        "↑": "arrow.up", "↓": "arrow.down", "←": "arrow.left", "→": "arrow.right",
        "↖": "arrow.up.left", "↘": "arrow.down.right",
        "⇞": "chevron.up.2", "⇟": "chevron.down.2",
        "⇥": "arrow.right.to.line",
    ]
    private static var ink: NSColor { Theme.current.chrome.ink(.muted) }

    /// The chord this keycap draws. Baked at construction (every token colors itself then), so a
    /// host whose glyph can change re-reads this and rebuilds rather than mutating in place.
    let shortcut: String
    private let showsBackground: Bool
    /// The glyph-token row, retained so `reapplyTheme()` can rebuild it — every token bakes its
    /// ink/tint color in at construction (there's nothing to mutate in place).
    private let tokenStack: NSStackView

    /// `showsBackground: false` renders just the glyph tokens with no rounded fill — for a host that
    /// supplies its own background (the keybind chip's full-width focus target). `size` defaults to
    /// `.regular`, so existing hosts are unchanged.
    init(shortcut: String, showsBackground: Bool = true) {
        self.shortcut = shortcut
        self.showsBackground = showsBackground
        // A horizontal run of icon/text tokens; the spacing keeps the glyphs from crowding.
        let stack = NSStackView(views: Self.tokens(for: shortcut))
        stack.orientation = .horizontal
        stack.spacing = Self.tokenSpacing
        stack.alignment = .centerY
        tokenStack = stack
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        if showsBackground { layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor }
        translatesAutoresizingMaskIntoConstraints = false

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Report the width the internal leading/trailing pins already produce, so Auto Layout's
    /// hugging/compression machinery actually engages: without an intrinsic size, a keycap is the one
    /// elastic view in a stack and absorbs any slack, stretching a one-glyph box into a wide pill next to
    /// a lower-hugging label. This only *reports* the existing geometry — it adds no constraint — so every
    /// consumer that never wanted a stretched keycap (all of them) is unaffected.
    override var intrinsicContentSize: NSSize {
        NSSize(width: tokenStack.fittingSize.width + Self.horizontalInset * 2, height: Self.height)
    }

    /// Re-apply the live chrome colors after a config change — no relaunch. Every token (modifier
    /// icon tint, key-label ink) bakes its color in at construction, so rebuild them fresh against
    /// `Theme.current` rather than mutate in place — the same pattern `KeybindRow.reapplyTheme()`
    /// already uses for its nested `KeycapView` (re-render, don't patch).
    func reapplyTheme() {
        if showsBackground { layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor }
        tokenStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        Self.tokens(for: shortcut).forEach { tokenStack.addArrangedSubview($0) }
        invalidateIntrinsicContentSize()  // the token run changed, so the reported width may have too
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
        view.image = glyphImage(symbol, pointSize: Self.symbolPointSize)
        view.contentTintColor = ink
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    /// Identifies a cached glyph. The point size stays in the key even though one footprint ships:
    /// a symbol-only key would hand whichever size rendered first to every later keycap, and that
    /// is invisible on screen.
    private struct GlyphKey: Hashable {
        let symbol: String
        let pointSize: CGFloat
    }

    /// The glyph images, resolved once per symbol/size and shared by every keycap on screen. The tint
    /// lives on the image VIEW (`contentTintColor`), never on the image, so sharing one instance is
    /// safe and `reapplyTheme()` still recolors. The palette rebuilds rows per keystroke, which made
    /// this a symbol lookup per token per row. Main-thread only, like the views it feeds.
    private static var glyphImages: [GlyphKey: NSImage?] = [:]

    private static func glyphImage(_ symbol: String, pointSize: CGFloat) -> NSImage? {
        let key = GlyphKey(symbol: symbol, pointSize: pointSize)
        if let cached = glyphImages[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
            .withSymbolConfiguration(config)
        glyphImages[key] = image
        return image
    }

    private static func keyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: Self.labelFontSize, weight: .medium)
        label.textColor = ink
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
