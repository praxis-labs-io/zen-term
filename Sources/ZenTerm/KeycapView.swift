import AppKit
import TerminalKit

final class KeycapView: NSView {
    private static let height: CGFloat = 20
    private static let horizontalInset: CGFloat = 7
    private static let cornerRadius: CGFloat = 6
    private static let tokenSpacing: CGFloat = 3
    private static let symbolPointSize: CGFloat = 10
    private static let labelFontSize: CGFloat = 11

    private static let glyphSymbols: [Character: String] = [
        "⌘": "command", "⇧": "shift", "⌥": "option", "⌃": "control",
        "⏎": "return", "↵": "return", "⎋": "escape",
        "↑": "arrow.up", "↓": "arrow.down", "←": "arrow.left", "→": "arrow.right",
        "↖": "arrow.up.left", "↘": "arrow.down.right",
        "⇞": "chevron.up.2", "⇟": "chevron.down.2",
        "⇥": "arrow.right.to.line",
    ]
    enum Style {
        case chip
        case plain
        case glyph(ink: KeyPath<ChromeTheme, TerminalColor>)
    }

    let shortcut: String
    private let style: Style
    private let tokenStack: NSStackView

    init(shortcut: String, style: Style = .chip) {
        self.shortcut = shortcut
        self.style = style
        let stack = NSStackView(views: Self.tokens(for: shortcut, ink: Self.ink(style)))
        stack.orientation = .horizontal
        stack.spacing = Self.tokenSpacing
        stack.alignment = .centerY
        tokenStack = stack
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.backgroundColor = Self.background(style)?.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset(style)),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset(style)),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var inkForTesting: NSColor? {
        switch tokenStack.arrangedSubviews.first {
        case let icon as NSImageView: return icon.contentTintColor
        case let label as NSTextField: return label.textColor
        default: return nil
        }
    }

    /// Without it a keycap is the elastic view in a stack and stretches into a pill.
    override var intrinsicContentSize: NSSize {
        NSSize(width: tokenStack.fittingSize.width + Self.inset(style) * 2, height: Self.height)
    }

    func reapplyTheme() {
        layer?.backgroundColor = Self.background(style)?.cgColor
        tokenStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        Self.tokens(for: shortcut, ink: Self.ink(style)).forEach { tokenStack.addArrangedSubview($0) }
        invalidateIntrinsicContentSize()
    }

    private static func inset(_ style: Style) -> CGFloat {
        switch style {
        case .chip, .plain: return horizontalInset
        case .glyph: return 0
        }
    }

    private static func background(_ style: Style) -> NSColor? {
        switch style {
        case .chip: return Theme.current.chrome.fill(.rest)
        case .plain, .glyph: return nil
        }
    }

    private static func ink(_ style: Style) -> NSColor {
        let chrome = Theme.current.chrome
        switch style {
        case .chip, .plain: return chrome.ink(.subtle)
        case .glyph(let ink): return chrome[keyPath: ink].nsColor
        }
    }

    private static func tokens(for shortcut: String, ink: NSColor) -> [NSView] {
        var views: [NSView] = []
        var run = ""
        func flushRun() {
            if !run.isEmpty {
                views.append(keyLabel(run, ink: ink))
                run = ""
            }
        }
        for ch in shortcut {
            if let symbol = glyphSymbols[ch] {
                flushRun()
                views.append(modifierIcon(symbol, ink: ink))
            } else {
                run.append(ch)
            }
        }
        flushRun()
        return views
    }

    private static func modifierIcon(_ symbol: String, ink: NSColor) -> NSView {
        let view = NSImageView()
        view.image = glyphImage(symbol, pointSize: Self.symbolPointSize)
        view.contentTintColor = ink
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    /// Keeps the point size, or a symbol's first rendered size would leak to every later keycap.
    private struct GlyphKey: Hashable {
        let symbol: String
        let pointSize: CGFloat
    }

    /// Shared safely because the tint lives on the image view. Main thread only.
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

    private static func keyLabel(_ text: String, ink: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: Self.labelFontSize, weight: .medium)
        label.textColor = ink
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
