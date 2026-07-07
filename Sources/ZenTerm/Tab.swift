import TabKit

/// The chrome's per-tab record beyond the pane controller: its id and last-known
/// title (cached so the tab bar can render without re-querying every controller).
/// The controller itself lives in `WindowController`'s `[TabID: PaneCanvasController]`.
struct Tab {
    let id: TabID
    var title: String
}
