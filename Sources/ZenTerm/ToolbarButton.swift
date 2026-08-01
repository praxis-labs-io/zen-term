/// The footer toolbar's built-in buttons, in toolbar order. The raw value is the config slug the
/// `hide-toolbar-buttons` list uses. Hiding a button is purely visual: its chord and palette
/// entry stay live, so the slugs never touch `KeyInterceptor` or `CommandCatalog`.
enum ToolbarButton: String, CaseIterable {
    case newTab = "new-tab"
    case splitHorizontal = "split-h"
    case splitVertical = "split-v"
    case bottomDrawer = "bottom-drawer"
    case rightDrawer = "right-drawer"
    case focusMode = "focus-mode"
    case commandPalette = "command-palette"
    case diffViewer = "diff-viewer"

    /// The divider grouping: create │ layout │ overlays. The tool-float group is not here —
    /// `ToggleDock` appends it from the float catalog, since its membership is config-driven.
    static let groups: [[ToolbarButton]] = [
        [.newTab],
        [.splitHorizontal, .splitVertical, .bottomDrawer, .rightDrawer, .focusMode],
        [.commandPalette, .diffViewer],
    ]

    /// The Settings checkbox label.
    var displayName: String {
        switch self {
        case .newTab: return "New tab"
        case .splitHorizontal: return "Split horizontally"
        case .splitVertical: return "Split vertically"
        case .bottomDrawer: return "Bottom drawer"
        case .rightDrawer: return "Right drawer"
        case .focusMode: return "Focus mode"
        case .commandPalette: return "Command palette"
        case .diffViewer: return "Diff viewer"
        }
    }
}
