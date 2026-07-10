import AppKit

/// The global footer toggle dock (bottom-right of the tab-bar row): a row of `IconButton`s
/// — split-h, split-v │ bottom drawer, right drawer, zoom │ repo picker, lazygit, one per
/// `ToolFloatCatalog` entry — grouped by thin dividers. Active toggles tint iris. Buttons
/// fire injected closures (routed through the window's chord handler, so they respect the
/// modals). `render` mirrors the active tab's overlay state plus the window's repo-picker
/// state.
final class ToggleDock: NSView {
    private let paletteBtn: IconButton
    private let bottomBtn: IconButton
    private let rightBtn: IconButton
    private let zoomBtn: IconButton
    private let lazygitBtn: IconButton
    private var toolFloatBtns: [String: IconButton] = [:]

    private static let iconPointSize: CGFloat = 11

    init(
        onSplitH: @escaping () -> Void, onSplitV: @escaping () -> Void,
        onPalette: @escaping () -> Void, onBottom: @escaping () -> Void,
        onRight: @escaping () -> Void, onZoom: @escaping () -> Void,
        onLazygit: @escaping () -> Void,
        toolFloats: [ToolFloat], onToolFloat: @escaping (ToolFloat) -> Void
    ) {
        func button(_ symbol: String, _ label: String, _ onClick: @escaping () -> Void) -> IconButton {
            IconButton(symbol: symbol, pointSize: Self.iconPointSize, accessibilityLabel: label, onClick: onClick)
        }
        let splitH = button("rectangle.split.1x2", "Split horizontally", onSplitH)  // ⌘- stacked
        let splitV = button("rectangle.split.2x1", "Split vertically", onSplitV)  // ⌘⇧\ side-by-side
        paletteBtn = button("command", "Command palette", onPalette)  // ⌘P
        bottomBtn = button("rectangle.bottomthird.inset.filled", "Toggle bottom drawer", onBottom)  // ⌘B
        rightBtn = button("rectangle.trailingthird.inset.filled", "Toggle right drawer", onRight)  // ⌘\
        zoomBtn = button("arrow.up.left.and.arrow.down.right", "Toggle zoom", onZoom)  // ⌘F
        lazygitBtn = button("git", "Toggle lazygit", onLazygit)  // ⌘G — bundled git mark
        // Local pairs — `button` is a local func, but the `toolFloatBtns` stored
        // property can't be touched until after super.init.
        let toolButtonPairs: [(String, IconButton)] = toolFloats.map { spec in
            (spec.id, button(spec.icon, spec.title, { onToolFloat(spec) }))
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for (id, btn) in toolButtonPairs { toolFloatBtns[id] = btn }

        let stack = NSStackView(
            views: [
                splitH, splitV, Self.divider(),
                bottomBtn, rightBtn, zoomBtn, Self.divider(),
                paletteBtn, lazygitBtn,
            ] + toolButtonPairs.map(\.1))
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

    /// Mirror the active tab's overlay state (drawers, lazygit, zoom) and the window's
    /// repo picker; split buttons are momentary and have no active state. A modal float
    /// (lazygit / tool float) covers the whole tab, so while one is open the zoom and drawer
    /// pips dim — their state is hidden behind it and returns when it closes. Otherwise the
    /// drawer tints reflect what's visible: a zoomed pane hides both drawers (neither lit), a
    /// zoomed drawer hides its sibling (only its own lit).
    func render(overlay: OverlayState, paletteOpen: Bool) {
        paletteBtn.isActive = paletteOpen
        lazygitBtn.isActive = overlay.isLazygitOpen
        for (id, btn) in toolFloatBtns { btn.isActive = overlay.activeToolFloatID == id }

        // A float covers the tab, so zoom/drawer state beneath it would read as lit-but-hidden.
        if overlay.isLazygitOpen || overlay.activeToolFloatID != nil {
            zoomBtn.isActive = false
            bottomBtn.isActive = false
            rightBtn.isActive = false
            return
        }

        zoomBtn.isActive = overlay.zoomed != nil
        switch overlay.zoomed {
        case nil:
            bottomBtn.isActive = overlay.isBottomOpen
            rightBtn.isActive = overlay.isRightOpen
        case .pane:
            bottomBtn.isActive = false
            rightBtn.isActive = false
        case .bottomDrawer:
            bottomBtn.isActive = true
            rightBtn.isActive = false
        case .rightDrawer:
            bottomBtn.isActive = false
            rightBtn.isActive = true
        }
    }

    /// A thin 1×12 vertical divider matching the demo's group separators.
    private static func divider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.current.chrome.ink(alpha: 0.10).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return v
    }
}
