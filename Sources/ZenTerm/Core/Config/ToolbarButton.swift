/// The raw value is the `hide-toolbar-buttons` slug.
enum ToolbarButton: String, CaseIterable {
    case newTab = "new-tab"
    case bottomDrawer = "bottom-drawer"
    case rightDrawer = "right-drawer"
    case scratch = "scratch"
    case commandPalette = "command-palette"
    case keepAwake = "keep-awake"
    case settings = "settings"

    static let groups: [[ToolbarButton]] = [
        [.newTab],
        [.bottomDrawer, .rightDrawer, .scratch],
    ]

    var displayName: String {
        switch self {
        case .newTab: return "New tab"
        case .bottomDrawer: return "Bottom drawer"
        case .rightDrawer: return "Right drawer"
        case .scratch: return "Scratch"
        case .commandPalette: return "Command palette"
        case .keepAwake: return "Keep Awake"
        case .settings: return "Settings"
        }
    }
}
