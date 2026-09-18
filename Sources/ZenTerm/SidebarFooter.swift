import AppKit

/// The docked sidebar's palette and Settings buttons, placed on the window beside the toggle so they fade, not slide.
final class SidebarFooter: NSStackView {
    static let spacing: CGFloat = 2
    static let buttonSize = NSSize(width: 22, height: 22)
    private static let iconPointSize: CGFloat = 11

    private let paletteButton: IconButton
    private let settingsButton: IconButton

    static func button(
        _ symbol: String, _ label: String, _ action: KeyInterceptor.ReservedChord, _ onClick: @escaping () -> Void
    ) -> IconButton {
        IconButton(
            symbol: symbol, size: buttonSize, pointSize: iconPointSize,
            accessibilityLabel: label, shortcut: { CommandCatalog.spec(for: action).shortcut }, onClick: onClick)
    }

    init(onPalette: @escaping () -> Void, onSettings: @escaping () -> Void) {
        paletteButton = Self.button("command", "Command palette", .toggleCommandPalette, onPalette)
        settingsButton = Self.button("gearshape", "Settings", .openSettings, onSettings)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = Self.spacing
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        addArrangedSubview(paletteButton)
        addArrangedSubview(settingsButton)
        heightAnchor.constraint(equalToConstant: Self.buttonSize.height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setHiddenButtons(_ hidden: Set<ToolbarButton>) {
        paletteButton.isHidden = hidden.contains(.commandPalette)
        settingsButton.isHidden = hidden.contains(.settings)
    }

    func setOpenModal(palette: Bool, settings: Bool) {
        paletteButton.isActive = palette
        settingsButton.isActive = settings
    }

    func reapplyTheme() {
        for button in [paletteButton, settingsButton] { button.reapplyTheme() }
    }

    var paletteButtonForTesting: IconButton { paletteButton }
    var settingsButtonForTesting: IconButton { settingsButton }
}
