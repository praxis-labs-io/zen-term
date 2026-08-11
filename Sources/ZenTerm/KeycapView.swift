import AppKit

/// A small rounded box holding a keyboard shortcut, e.g. ⌘⇧P. Modifier glyphs render as
/// crisp SF Symbols (command/shift/option/control); the key itself renders as muted
/// monospaced text. Shares the chrome's rounded-6 box idiom with `IconButton` and the
/// tab-bar `Chip`: faint fill, muted ink. Shown at a command-palette row's trailing edge.
final class KeycapView: NSView {
    /// The two footprints a keycap draws at: `regular` for command-palette rows and settings chips,
    /// `compact` for the diff viewer's dense footer legend. Only the metrics differ — the
    /// glyph/text split and theming are shared.
    enum Size {
        case regular, compact
        var height: CGFloat { self == .compact ? 16 : 20 }
        var horizontalInset: CGFloat { self == .compact ? 5 : 7 }
        var cornerRadius: CGFloat { self == .compact ? 5 : 6 }
        var tokenSpacing: CGFloat { self == .compact ? 2 : 3 }
        var symbolPointSize: CGFloat { self == .compact ? 9 : 10 }
        var labelFontSize: CGFloat { self == .compact ? 10 : 11 }
    }

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
    private static var ink: NSColor { Theme.current.chrome.ink(alpha: 0.55) }

    /// The chord this keycap draws. Baked at construction (every token colors itself then), so a
    /// host whose glyph can change re-reads this and rebuilds rather than mutating in place.
    let shortcut: String
    private let showsBackground: Bool
    private let size: Size
    /// The glyph-token row, retained so `reapplyTheme()` can rebuild it — every token bakes its
    /// ink/tint color in at construction (there's nothing to mutate in place).
    private let tokenStack: NSStackView

    /// `showsBackground: false` renders just the glyph tokens with no rounded fill — for a host that
    /// supplies its own background (the keybind chip's full-width focus target). `size` defaults to
    /// `.regular`, so existing hosts are unchanged.
    init(shortcut: String, showsBackground: Bool = true, size: Size = .regular) {
        self.shortcut = shortcut
        self.showsBackground = showsBackground
        self.size = size
        // A horizontal run of icon/text tokens; the spacing keeps the glyphs from crowding.
        let stack = NSStackView(views: Self.tokens(for: shortcut, size: size))
        stack.orientation = .horizontal
        stack.spacing = size.tokenSpacing
        stack.alignment = .centerY
        tokenStack = stack
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = size.cornerRadius
        if showsBackground { layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor }
        translatesAutoresizingMaskIntoConstraints = false

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: size.horizontalInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -size.horizontalInset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: size.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Report the width the internal leading/trailing pins already produce, so Auto Layout's
    /// hugging/compression machinery actually engages: without an intrinsic size, a keycap is the one
    /// elastic view in a stack and absorbs any slack, stretching a one-glyph box into a wide pill next to
    /// a lower-hugging label. This only *reports* the existing geometry — it adds no constraint — so every
    /// consumer that never wanted a stretched keycap (all of them) is unaffected.
    override var intrinsicContentSize: NSSize {
        NSSize(width: tokenStack.fittingSize.width + size.horizontalInset * 2, height: size.height)
    }

    /// Re-apply the live chrome colors after a config change — no relaunch. Every token (modifier
    /// icon tint, key-label ink) bakes its color in at construction, so rebuild them fresh against
    /// `Theme.current` rather than mutate in place — the same pattern `KeybindRow.reapplyTheme()`
    /// already uses for its nested `KeycapView` (re-render, don't patch).
    func reapplyTheme() {
        if showsBackground { layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.08).cgColor }
        tokenStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        Self.tokens(for: shortcut, size: size).forEach { tokenStack.addArrangedSubview($0) }
        invalidateIntrinsicContentSize()  // the token run changed, so the reported width may have too
    }

    /// Split the shortcut into views: an SF Symbol per modifier glyph and a monospaced
    /// text run for each maximal stretch of key characters.
    private static func tokens(for shortcut: String, size: Size) -> [NSView] {
        var views: [NSView] = []
        var run = ""
        func flushRun() {
            if !run.isEmpty {
                views.append(keyLabel(run, size: size))
                run = ""
            }
        }
        for ch in shortcut {
            if let symbol = glyphSymbols[ch] {
                flushRun()
                views.append(modifierIcon(symbol, size: size))
            } else {
                run.append(ch)
            }
        }
        flushRun()
        return views
    }

    private static func modifierIcon(_ symbol: String, size: Size) -> NSView {
        let view = NSImageView()
        view.image = glyphImage(symbol, pointSize: size.symbolPointSize)
        view.contentTintColor = ink
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    /// Identifies a cached glyph. The point size is part of the key because a keycap draws at more
    /// than one footprint (`Size.compact` renders 9pt against `.regular`'s 10pt), so a symbol-only
    /// key would hand whichever size rendered first to every later keycap.
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

    private static func keyLabel(_ text: String, size: Size) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: size.labelFontSize, weight: .medium)
        label.textColor = ink
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
