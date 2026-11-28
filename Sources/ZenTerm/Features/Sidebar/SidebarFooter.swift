import AppKit

// On the window beside the toggle, not in the sidebar, so these fade instead of sliding with it.
final class SidebarFooter: NSStackView {
    static let spacing: CGFloat = ChromeMetrics.Spacing.s4
    static let buttonSize = NSSize(width: ChromeMetrics.Height.sm, height: ChromeMetrics.Height.sm)
    // The sidebar toggle's glyph centers on the rows' chips, so the footer reads as one column with them.
    static let toggleInset =
        SidebarView.padding + ChromeMetrics.Spacing.controlInset + IconBadge.Size.small.side / 2 - buttonSize.width / 2

    private let paletteButton: IconButton
    let keepAwakeIndicator = KeepAwakeIndicator {}

    static func button(
        _ symbol: String, _ label: String, _ action: KeyInterceptor.ReservedChord, _ onClick: @escaping () -> Void
    ) -> IconButton {
        IconButton(
            symbol: symbol, size: buttonSize, pointSize: ChromeMetrics.Icon.sm,
            accessibilityLabel: label, shortcut: { CommandCatalog.spec(for: action).shortcut }, onClick: onClick)
    }

    init(onPalette: @escaping () -> Void) {
        paletteButton = Self.button("command", "Command palette", .toggleCommandPalette, onPalette)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = Self.spacing
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        addArrangedSubview(paletteButton)
        addArrangedSubview(keepAwakeIndicator)
        heightAnchor.constraint(equalToConstant: Self.buttonSize.height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setHiddenButtons(_ hidden: Set<ToolbarButton>) {
        paletteButton.isHidden = hidden.contains(.commandPalette)
        keepAwakeIndicator.isHidden = hidden.contains(.keepAwake)
    }

    func setPaletteOpen(_ open: Bool) { paletteButton.isActive = open }

    var paletteButtonForTesting: IconButton { paletteButton }
}
