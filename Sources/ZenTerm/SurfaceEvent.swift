import TerminalKit

/// One thing a terminal surface reported, travelling from the controller that owns the surface to
/// the window that acts on it.
///
/// One case-carrying event rather than a closure per kind. Both owners relay the same set —
/// `PaneCanvasController` for panes, `TabController` for drawers — so every kind used to cost a
/// closure property in each, a forwarding method in each, and a bridge line between them. Three
/// kinds in, that had become twelve declarations saying the same thing.
enum SurfaceEvent {
    /// The viewport moved within the buffer, or the buffer grew under it. Arrives on output too.
    case scrollPosition(TerminalScrollPosition)
    /// The grid changed shape and the text is rewrapping into it.
    case gridReflow
    case search(SearchController.Event)
}
