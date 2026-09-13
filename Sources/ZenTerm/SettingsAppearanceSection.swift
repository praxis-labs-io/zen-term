import AppKit
import TerminalKit

final class SettingsAppearanceSection: SettingsFormSection {
    override var navTitle: String { "Appearance" }

    private var themeEntries: [ThemeEntry] = []
    private weak var themeDropdown: Dropdown?
    private weak var accentDropdown: Dropdown?

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
        addGroup("Toolbar") {
            self.addToolbarButtonsRow()
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
                blurb: "How far each ⌘⌃arrow nudge resizes", range: 4...400, read: { $0.drawerResizeStep },
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

    private weak var toolbarList: CheckboxDropdown?

    private func addToolbarButtonsRow() {
        registerScalarKey("hide-toolbar-buttons")
        let list = CheckboxDropdown(
            title: Self.toolbarSummary(), items: Self.toolbarItems()
        ) { [weak self] index in
            guard let self else { return }
            var hidden = GeneralConfig.current.hiddenToolbarButtons
            let button = ToolbarButton.allCases[index]
            if hidden.contains(button) {
                hidden.remove(button)
            } else {
                hidden.insert(button)
            }
            self.writeOrRemove(
                "hide-toolbar-buttons",
                hidden.isEmpty ? nil : LayoutFormat.hideToolbarButtonsToken(hidden),
                row: "hide-toolbar-buttons")
        }
        toolbarList = list
        addCustomRow(
            key: "hide-toolbar-buttons", caption: "Toolbar buttons",
            description: "Shortcuts stay active when hidden",
            control: list, focusStop: list, controlNote: nil, width: 220,
            refresh: { [weak self] in
                self?.toolbarList?.setItems(Self.toolbarItems(), title: Self.toolbarSummary())
            })
    }

    /// Static so the stored closures don't retain the section.
    private static func toolbarItems() -> [CheckboxDropdownItem] {
        let hidden = GeneralConfig.current.hiddenToolbarButtons
        return ToolbarButton.allCases.map {
            CheckboxDropdownItem(title: $0.displayName, isChecked: !hidden.contains($0))
        }
    }

    private static func toolbarSummary() -> String {
        let hidden = GeneralConfig.current.hiddenToolbarButtons.count
        return hidden == 0 ? "All shown" : "\(hidden) hidden"
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
                group: entry.source == .user ? "Your themes" : "Bundled",
                note: entry.isDark ? "Dark" : "Light",
                isSelected: index == selected)
        }
    }

    private func currentThemeIndex() -> Int {
        let name = GeneralConfig.current.themeName ?? ThemeCatalog.defaultThemeName
        return themeEntries.firstIndex { $0.name == name } ?? 0
    }

    private func selectTheme(_ index: Int) {
        guard themeEntries.indices.contains(index) else { return }
        write("theme", themeEntries[index].name, row: "theme")
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
            description: "Focus, active states, confirms",
            control: dropdown, focusStop: dropdown, controlNote: nil, width: 220,
            refresh: { [weak self] in self?.refreshAccentRow() })
    }

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

    override func reapplyTheme() {
        super.reapplyTheme()
        refreshAccentRow()
    }

    /// Static so the stored read closure doesn't retain the section.
    private static func reduceMotionIndex(_ config: GeneralConfig) -> Int {
        switch config.reduceMotion {
        case .on: return 0
        case .off: return 1
        case .system: return Motion.isReduceMotionEnabled() ? 0 : 1
        }
    }
}
