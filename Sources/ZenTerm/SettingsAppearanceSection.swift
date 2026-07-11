import AppKit

/// The Appearance settings section: theme picker (Task 7) plus the chrome Layout knobs and the
/// Motion preference. A subclass of `SettingsFormSection` — it only declares its groups; the base
/// owns the row builders, live-apply debounce, focus stops, and Reset-all.
final class SettingsAppearanceSection: SettingsFormSection {
    override var navTitle: String { "Appearance" }

    private var themeEntries: [ThemeEntry] = []
    private weak var themeDropdown: Dropdown?
    private let restartButton = AppButton(title: "Restart to apply", variant: .primary)

    override func populate() {
        addGroup("Theme") { self.addThemeRow() }
        addGroup("Layout") {
            self.addNumericRow(
                key: "backdrop-alpha", caption: "Backdrop alpha", blurb: "Tint strength over the window blur",
                range: 0...1, read: { $0.backdropAlpha }, width: 64)
            self.addNumericRow(
                key: "window-gutter", caption: "Window gutter", blurb: "Space around the window edge",
                range: 0...64, read: { $0.windowGutter }, width: 64)
            self.addNumericRow(
                key: "pane-gap", caption: "Pane gap", blurb: "Space between split panes",
                range: 0...64, read: { $0.panelGap }, width: 64)
            self.addNumericRow(
                key: "bottom-drawer-fraction", caption: "Default bottom drawer height",
                blurb: "Height it opens to (new tabs)", range: 0.1...0.9, read: { $0.bottomDrawerFraction },
                width: 64)
            self.addNumericRow(
                key: "right-drawer-fraction", caption: "Default right drawer width",
                blurb: "Width it opens to (new tabs)", range: 0.1...0.9, read: { $0.rightDrawerFraction },
                width: 64)
            self.addNumericRow(
                key: "drawer-resize-step", caption: "Drawer resize step",
                blurb: "How far each ⌥-arrow nudge resizes", range: 4...400, read: { $0.drawerResizeStep },
                width: 64)
            self.addNumericRow(
                key: "max-drawer-fraction", caption: "Max drawer width/height",
                blurb: "Largest a drawer can grow", range: 0.3...0.95, read: { $0.maxDrawerFraction }, width: 64)
        }
        addGroup("Motion") {
            self.addSegmentedRow(
                key: "reduce-motion", caption: "Reduce motion", blurb: nil, options: ["On", "Off"],
                read: { Self.reduceMotionIndex($0) },
                token: { LayoutFormat.reduceMotionToken($0 == 0 ? .on : .off) }, notifiesOnReselect: true)
        }
    }

    private func addThemeRow() {
        themeEntries = ThemeCatalog.entries()
        let selected = currentThemeIndex()
        let dropdown = Dropdown(items: themeItems(selected: selected), selectedIndex: selected) {
            [weak self] index in self?.selectTheme(index)
        }
        themeDropdown = dropdown
        restartButton.isKeyboardFocusable = false
        restartButton.isHidden = true
        restartButton.onTap = { Relauncher.relaunch() }

        // A trailing control column: the dropdown with the restart button tucked under it.
        addCustomRow(
            key: "theme", caption: "Theme", description: "Applies on restart",
            control: dropdown, focusStop: dropdown, controlNote: nil, width: 220,
            refresh: { [weak self] in self?.refreshThemeRow() })
        // Place the restart button under the dropdown row (added as its own arranged view).
        appendTrailing(restartButton)
    }

    private func themeItems(selected: Int) -> [DropdownItem] {
        themeEntries.enumerated().map { index, entry in
            DropdownItem(
                title: entry.displayName,
                group: entry.source == .user ? "Your themes" : (entry.source == .bundled ? "Bundled" : nil),
                note: entry.isDark ? "Dark" : "Light",
                isSelected: index == selected)
        }
    }

    private func currentThemeIndex() -> Int {
        let name = GeneralConfig.current.themeName
        return themeEntries.firstIndex { $0.name == name } ?? 0
    }

    private func selectTheme(_ index: Int) {
        guard themeEntries.indices.contains(index) else { return }
        let entry = themeEntries[index]
        if let name = entry.name {
            write("theme", name, row: "theme")
        } else {
            writeOrRemove("theme", nil, row: "theme")  // built-in default clears the key
        }
        updateRestartVisibility()
    }

    private func refreshThemeRow() {
        let selected = currentThemeIndex()
        themeDropdown?.setItems(themeItems(selected: selected), selectedIndex: selected)
        updateRestartVisibility()
    }

    /// Show "Restart to apply" only when the chosen theme differs from the running one.
    private func updateRestartVisibility() {
        let chosen = GeneralConfig.current.themeName
        restartButton.isHidden = (chosen == Self.launchThemeName)
    }

    private static let launchThemeName: String? = GeneralConfig.current.themeName

    /// Reduce-motion shown as On/Off; `system` resolves via the OS accessibility setting. Static so the
    /// `read` closure the base stores per row doesn't capture `self` (which would retain-cycle through
    /// the section's `refreshers`); it reads only the passed config and the OS setting.
    private static func reduceMotionIndex(_ config: GeneralConfig) -> Int {
        switch config.reduceMotion {
        case .on: return 0
        case .off: return 1
        case .system: return Motion.isReduceMotionEnabled() ? 0 : 1
        }
    }
}
