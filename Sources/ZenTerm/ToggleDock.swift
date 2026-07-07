import AppKit

/// A tab's overlay open-state, mirrored by the toggle dock's active tints.
struct OverlayState: Equatable {
    var isBottomOpen = false
    var isRightOpen = false
    var isLazygitOpen = false
}

/// The global footer toggle dock (bottom-right of the tab-bar row): a row of icon
/// buttons — split-h, split-v │ command palette, bottom drawer, right drawer │ lazygit —
/// grouped by thin dividers. Active toggles tint iris. Buttons fire injected closures
/// (routed through the window's chord handler, so they respect the modals). `render`
/// mirrors the active tab's overlay state plus the window's repo-picker state.
final class ToggleDock: NSView {
    private let paletteBtn: DockButton
    private let bottomBtn: DockButton
    private let rightBtn: DockButton
    private let lazygitBtn: DockButton

    init(onSplitH: @escaping () -> Void, onSplitV: @escaping () -> Void,
         onPalette: @escaping () -> Void, onBottom: @escaping () -> Void,
         onRight: @escaping () -> Void, onLazygit: @escaping () -> Void) {
        let splitH = DockButton(symbol: "rectangle.split.1x2", onClick: onSplitH)   // ⌘- stacked
        let splitV = DockButton(symbol: "rectangle.split.2x1", onClick: onSplitV)   // ⌘⇧\ side-by-side
        paletteBtn = DockButton(symbol: "command", onClick: onPalette)              // ⌘P
        bottomBtn = DockButton(symbol: "rectangle.bottomthird.inset.filled", onClick: onBottom)  // ⌘B
        rightBtn = DockButton(symbol: "rectangle.trailingthird.inset.filled", onClick: onRight)  // ⌘\
        lazygitBtn = DockButton(symbol: "arrow.triangle.branch", onClick: onLazygit)             // ⌘G
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            splitH, splitV, Self.divider(),
            paletteBtn, bottomBtn, rightBtn, Self.divider(),
            lazygitBtn,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Mirror the active tab's overlay state (drawers, lazygit) and the window's repo
    /// picker; split buttons are momentary and have no active state.
    func render(overlay: OverlayState, paletteOpen: Bool) {
        paletteBtn.isActive = paletteOpen
        bottomBtn.isActive = overlay.isBottomOpen
        rightBtn.isActive = overlay.isRightOpen
        lazygitBtn.isActive = overlay.isLazygitOpen
    }

    /// A thin 1×12 vertical divider matching the demo's group separators.
    private static func divider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return v
    }

    private static let iris = NSColor(srgbRed: 0xc4 / 255.0, green: 0xa7 / 255.0, blue: 0xe7 / 255.0, alpha: 1)

    /// A 24×24 rounded icon button: idle muted, hover brightens with a faint background,
    /// active tints iris (icon + 15% background) — matching the demo's dock buttons.
    private final class DockButton: NSView {
        private let onClick: () -> Void
        private let icon = NSImageView()
        private var trackingArea: NSTrackingArea?
        private var isHovered = false { didSet { update() } }
        var isActive = false { didSet { update() } }

        init(symbol: String, onClick: @escaping () -> Void) {
            self.onClick = onClick
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 6
            let config = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium)
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            icon.imageScaling = .scaleNone
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: 24),
                heightAnchor.constraint(equalToConstant: 24),
                icon.centerXAnchor.constraint(equalTo: centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            update()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: bounds,
                                     options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                     owner: self)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { isHovered = true }
        override func mouseExited(with event: NSEvent) { isHovered = false }
        override func mouseDown(with event: NSEvent) { onClick() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

        private func update() {
            let bg: NSColor
            let tint: NSColor
            if isActive {
                bg = ToggleDock.iris.withAlphaComponent(0.15); tint = ToggleDock.iris
            } else if isHovered {
                bg = NSColor(white: 1, alpha: 0.08); tint = NSColor(white: 1, alpha: 0.9)
            } else {
                bg = .clear; tint = NSColor(white: 1, alpha: 0.5)
            }
            layer?.backgroundColor = bg.cgColor
            icon.contentTintColor = tint
        }
    }
}
