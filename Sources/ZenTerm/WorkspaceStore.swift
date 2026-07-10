import Foundation

/// The configured workspaces, loaded once at launch from `~/.config/zen-term/workspaces`
/// (mirrors `Theme.current` / `GeneralConfig.current`). The `⌘⇧P` picker lists these; the
/// list is deliberate and hand-curated — there is no directory scanning.
enum WorkspaceStore {
    static let all: [Workspace] = ConfigLoader.loadWorkspaces()

    static func byTitle(_ title: String) -> Workspace? {
        all.first { $0.title == title }
    }
}
