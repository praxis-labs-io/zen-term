/// The raw value is the `hide-toolbar-buttons` slug.
enum ToolbarButton: String, CaseIterable {
    case newTab = "new-tab"
    case splitHorizontal = "split-h"
    case splitVertical = "split-v"
    case bottomDrawer = "bottom-drawer"
    case rightDrawer = "right-drawer"
    case scratch = "scratch"
    case focusMode = "focus-mode"
    case commandPalette = "command-palette"

    static let groups: [[ToolbarButton]] = [
        [.newTab],
        [.splitHorizontal, .splitVertical, .bottomDrawer, .rightDrawer, .scratch, .focusMode],
        [.commandPalette],
    ]

    var displayName: String {
        switch self {
        case .newTab: return "New tab"
        case .splitHorizontal: return "Split horizontally"
        case .splitVertical: return "Split vertically"
        case .bottomDrawer: return "Bottom drawer"
        case .rightDrawer: return "Right drawer"
        case .scratch: return "Scratch"
        case .focusMode: return "Focus mode"
        case .commandPalette: return "Command palette"
        }
    }
}
