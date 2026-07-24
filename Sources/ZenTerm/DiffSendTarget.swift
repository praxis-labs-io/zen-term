import PaneKit

/// A terminal in the active tab that a diff comment can be sent to: a pane or an open drawer, named
/// the way the composer's dropdown lists it.
///
/// `id` lives in the tab's shared nav id space, so `TabController` resolves it back to a surface and
/// focuses that panel with the same call the ⌃-nav keys use. The chrome never holds the surface
/// itself: the viewer is handed a list of these and hands one back.
struct DiffSendTarget: Equatable {
    let id: PaneID
    let label: String
}

/// What a finished diff comment does to its target terminal (ZEN-257).
enum DiffSendAction: Equatable {
    /// Paste the comment and press Return — the agent gets it now. The viewer closes.
    case submit
    /// Paste the comment followed by a newline, without submitting or stealing focus, and leave the
    /// viewer open. Lets several comments stack in the target's input (each on its own line) before a
    /// final `submit` fires them together.
    case queue
}
