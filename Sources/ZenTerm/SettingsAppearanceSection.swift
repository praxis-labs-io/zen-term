import AppKit
import TerminalKit

/// The Appearance settings section: theme and accent pickers plus the chrome Layout knobs and the
/// Motion preference. A subclass of `SettingsFormSection` — it only declares its groups; the base
/// owns the row builders, live-apply debounce, focus stops, and Reset-all.
final class SettingsAppearanceSection: SettingsFormSection {
    override var navTitle: String { "Appearance" }

    private var themeEntries: [ThemeEntry] = []
    private weak var themeDropdown: Dropdown?
    private weak var accentDropdown: Dropdown?

    /// The accent picker's rows: "Theme default" first, then the 16 ANSI slots. Index 0 clears the
    /// key, so it stays correct when a theme swap moves what the default resolves to.
    private static let accentSlots: [AccentSlot?] = [nil] + AccentSlot.allCases

    override func populate() {
        addGroup("Theme") {
            self.addThemeRow()
            self.addAccentRow()
        }
        addGroup("Window") {
            self.addSegmentedRow(
                key: "window-chrome", caption: "Window buttons",
                blurb: "Show the standard macOS window buttons", options: ["On", "Off"],
                read: { $0.windowChrome ? 0 : 1 },
                token: { LayoutFormat.boolToken($0 == 0) }, notifiesOnReselect: false)
        }
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
                blurb: "How far each ⌘⇧HJKL nudge resizes", range: 4...400, read: { $0.drawerResizeStep },
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

        addCustomRow(
            key: "theme", caption: "Theme", description: "Applies instantly",
            control: dropdown, focusStop: dropdown, controlNote: nil, width: 220,
            refresh: { [weak self] in self?.refreshThemeRow() })
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
    }

    private func refreshThemeRow() {
        let selected = currentThemeIndex()
        themeDropdown?.setItems(themeItems(selected: selected), selectedIndex: selected)
    }

    private func addAccentRow() {
        let selected = currentAccentIndex()
        let dropdown = Dropdown(items: accentItems(selected: selected), selectedIndex: selected) {
            [weak self] index in self?.selectAccent(index)
        }
        accentDropdown = dropdown

        addCustomRow(
            key: "accent-color", caption: "Accent color",
            description: "The color for focus, active state, and confirm",
            control: dropdown, focusStop: dropdown, controlNote: nil, width: 220,
            refresh: { [weak self] in self?.refreshAccentRow() })
    }

    /// Swatches and hexes resolve against the *live* theme, so switching theme re-renders this row
    /// with the new palette's colors under the same names.
    private func accentItems(selected: Int) -> [DropdownItem] {
        let terminal = Theme.current.terminal
        return Self.accentSlots.enumerated().map { index, slot in
            let resolved = (slot ?? .themeDefault).color(in: terminal)
            return DropdownItem(
                title: slot?.displayName ?? "Theme default",
                group: slot.map { $0.isBright ? "Bright" : "Normal" },
                note: resolved.hex,
                isSelected: index == selected,
                swatch: resolved.nsColor)
        }
    }

    private func currentAccentIndex() -> Int {
        let slot = GeneralConfig.current.accentColor
        return Self.accentSlots.firstIndex { $0 == slot } ?? 0
    }

    private func selectAccent(_ index: Int) {
        guard Self.accentSlots.indices.contains(index) else { return }
        writeOrRemove("accent-color", Self.accentSlots[index]?.rawValue, row: "accent-color")
    }

    private func refreshAccentRow() {
        let selected = currentAccentIndex()
        accentDropdown?.setItems(accentItems(selected: selected), selectedIndex: selected)
    }

    /// A theme change this card didn't make reaches sections through `reapplyTheme()`, which
    /// recolors controls but does not re-supply row *data* (`refreshRows()` runs only after this
    /// card's own write). The accent row is the only row whose contents are theme-derived, so
    /// without this its swatches and hexes keep the old palette until the section is rebuilt.
    /// The paths that get here: another window's Settings write, and ⌘⌥R after a hand-edit.
    override func reapplyTheme() {
        super.reapplyTheme()
        refreshAccentRow()
    }

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
