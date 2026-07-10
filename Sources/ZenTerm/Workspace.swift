import Foundation

/// One entry in the `⌘⇧P` workspace picker: a named working directory plus an open "recipe"
/// — which regions open and what each runs — and optional environment variables. Parsed
/// from a `[Title]` section of `~/.config/zen-term/workspaces`. The section header is the
/// `title`: shown in the picker and pinned as the tab name, independent of the folder name.
struct Workspace: Equatable {
    /// Which region receives focus once the recipe has been applied.
    enum Region: String { case main, right, bottom }

    let title: String
    let path: URL
    /// First-pane program; nil or `"shell"` → a plain shell.
    let main: String?
    /// Right-drawer command; nil → the drawer stays closed. `"shell"` → open as a plain shell.
    let right: String?
    /// Bottom-drawer command; nil → the drawer stays closed. `"shell"` → open as a plain shell.
    let bottom: String?
    /// Region focused after the recipe opens (default `.main`).
    let focus: Region
    /// Environment injected into every pane and drawer of this workspace.
    let env: [String: String]
}
