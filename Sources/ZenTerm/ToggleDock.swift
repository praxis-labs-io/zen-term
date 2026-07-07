import AppKit

/// The global footer toggle dock (bottom-right of the tab-bar row): a row of `IconButton`s
/// — split-h, split-v │ command palette, bottom drawer, right drawer │ lazygit — grouped
/// by thin dividers. Active toggles tint iris. Buttons fire injected closures (routed
/// through the window's chord handler, so they respect the modals). `render` mirrors the
/// active tab's overlay state plus the window's repo-picker state.
final class ToggleDock: NSView {
    private let paletteBtn: IconButton
    private let bottomBtn: IconButton
    private let rightBtn: IconButton
    private let lazygitBtn: IconButton

    private static let iconPointSize: CGFloat = 11

    init(onSplitH: @escaping () -> Void, onSplitV: @escaping () -> Void,
         onPalette: @escaping () -> Void, onBottom: @escaping () -> Void,
         onRight: @escaping () -> Void, onLazygit: @escaping () -> Void) {
        func button(_ symbol: String, _ label: String, _ onClick: @escaping () -> Void) -> IconButton {
            IconButton(symbol: symbol, pointSize: Self.iconPointSize, accessibilityLabel: label, onClick: onClick)
        }
        let splitH = button("rectangle.split.1x2", "Split horizontally", onSplitH)   // ⌘- stacked
        let splitV = button("rectangle.split.2x1", "Split vertically", onSplitV)     // ⌘⇧\ side-by-side
        paletteBtn = button("command", "Repo picker", onPalette)                     // ⌘P
        bottomBtn = button("rectangle.bottomthird.inset.filled", "Toggle bottom drawer", onBottom)  // ⌘B
        rightBtn = button("rectangle.trailingthird.inset.filled", "Toggle right drawer", onRight)   // ⌘\
        lazygitBtn = button("arrow.triangle.branch", "Toggle lazygit", onLazygit)                   // ⌘G
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
}
