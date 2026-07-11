import AppKit

/// The Appearance settings section: theme picker (Task 7) plus the chrome Layout knobs and the
/// Motion preference. A subclass of `SettingsFormSection` — it only declares its groups; the base
/// owns the row builders, live-apply debounce, focus stops, and Reset-all.
final class SettingsAppearanceSection: SettingsFormSection {
    override var navTitle: String { "Appearance" }

    override func populate() {
        // Theme group is added in Task 7 (needs the Dropdown + ThemeCatalog). Placeholder ordering:
        // it will be the first group, above Layout.
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
